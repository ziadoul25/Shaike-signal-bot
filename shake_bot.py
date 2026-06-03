#!/usr/bin/env python3
"""
SHAKE Telegram Signal Bot

Monitors XAUUSD and BTCUSD across M1, M5, and M15 timeframes using the
SHAKE moving-average strategy, then sends Telegram alerts when all three
configured timeframes confirm the same BUY or SELL direction.

This bot uses Yahoo Finance through yfinance as a free market-data source.
Free data feeds can be delayed, rate-limited, or temporarily unavailable, so
signals should be treated as informational and not as financial advice.
"""

from __future__ import annotations

import asyncio
import html
import json
import logging
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import pandas as pd
import yfinance as yf
from dotenv import load_dotenv
from telegram import Update
from telegram.constants import ParseMode
from telegram.ext import Application, ApplicationBuilder, CommandHandler, ContextTypes

BASE_DIR = Path(__file__).resolve().parent
LOG_DIR = BASE_DIR / "logs"
STATE_FILE = BASE_DIR / "signal_state.json"
ENV_FILE = BASE_DIR / ".env"

load_dotenv(ENV_FILE)

BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "").strip()
CHAT_ID_RAW = os.getenv("TELEGRAM_CHAT_ID", "").strip()
CHECK_INTERVAL_SECONDS = int(os.getenv("CHECK_INTERVAL_SECONDS", "60"))

FAST_MA_PERIOD = int(os.getenv("FAST_MA_PERIOD", "10"))
MEDIUM_MA_PERIOD = int(os.getenv("MEDIUM_MA_PERIOD", "25"))
SLOW_MA_PERIOD = int(os.getenv("SLOW_MA_PERIOD", "50"))

# Point-size assumptions are intentionally configurable. For XAUUSD, many
# brokers quote one point as 0.01. For BTCUSD, one point is commonly $1.
POINT_SIZES = {
    "XAUUSD": float(os.getenv("XAUUSD_POINT_SIZE", "0.01")),
    "BTCUSD": float(os.getenv("BTCUSD_POINT_SIZE", "1.0")),
}
STOP_LOSS_POINTS = float(os.getenv("STOP_LOSS_POINTS", "50"))
TAKE_PROFIT_POINTS = float(os.getenv("TAKE_PROFIT_POINTS", "100"))

TIMEFRAMES = {
    "M1": {"interval": "1m", "period": "2d"},
    "M5": {"interval": "5m", "period": "5d"},
    "M15": {"interval": "15m", "period": "10d"},
}

SYMBOL_TICKERS = {
    "XAUUSD": ["GC=F"],
    "BTCUSD": ["BTC-USD"],
}

last_check_time: Optional[datetime] = None
last_check_summary: str = "No checks completed yet."
bot_started_at: datetime = datetime.now(timezone.utc)
monitoring_task: Optional[asyncio.Task] = None
state_lock = asyncio.Lock()

LOG_DIR.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(name)s | %(message)s",
    handlers=[
        logging.FileHandler(LOG_DIR / "shake_bot.log"),
        logging.StreamHandler(),
    ],
)
logger = logging.getLogger("shake_bot")


@dataclass
class TimeframeSignal:
    timeframe: str
    direction: str
    price: float
    fast_ma: float
    medium_ma: float
    slow_ma: float
    bar_time: str
    ticker_used: str
    bars: int


@dataclass
class ConfirmedSignal:
    symbol: str
    direction: str
    entry_price: float
    stop_loss: float
    take_profit: float
    timeframe_signals: Dict[str, TimeframeSignal]
    detected_at: datetime


def parse_chat_id(value: str) -> int | str:
    """Telegram chat IDs can be integers or channel usernames."""
    if not value:
        raise ValueError("TELEGRAM_CHAT_ID is missing.")
    try:
        return int(value)
    except ValueError:
        return value


CHAT_ID = parse_chat_id(CHAT_ID_RAW) if CHAT_ID_RAW else None


def load_state() -> Dict[str, Any]:
    if not STATE_FILE.exists():
        return {"last_sent": {}}
    try:
        with STATE_FILE.open("r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            return {"last_sent": {}}
        data.setdefault("last_sent", {})
        return data
    except Exception as exc:  # noqa: BLE001
        logger.warning("Could not read state file %s: %s", STATE_FILE, exc)
        return {"last_sent": {}}


def save_state(state: Dict[str, Any]) -> None:
    temp_file = STATE_FILE.with_suffix(".tmp")
    with temp_file.open("w", encoding="utf-8") as f:
        json.dump(state, f, indent=2, sort_keys=True)
    temp_file.replace(STATE_FILE)


def fmt_price(value: float, symbol: str) -> str:
    if symbol == "BTCUSD":
        return f"{value:,.2f}"
    return f"{value:,.3f}"


def utc_now_text() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")


def fetch_history_for_ticker(ticker: str, interval: str, period: str) -> pd.DataFrame:
    """Fetch OHLCV history for a single Yahoo Finance ticker."""
    yf_ticker = yf.Ticker(ticker)
    df = yf_ticker.history(
        period=period,
        interval=interval,
        auto_adjust=False,
        actions=False,
        prepost=True,
        timeout=20,
    )
    if df is None or df.empty:
        raise ValueError(f"No data returned for {ticker} interval={interval} period={period}")

    if isinstance(df.columns, pd.MultiIndex):
        df.columns = [col[0] if isinstance(col, tuple) else col for col in df.columns]

    if "Close" not in df.columns:
        raise ValueError(f"Close column missing for {ticker}")

    df = df.dropna(subset=["Close"]).copy()
    if df.empty:
        raise ValueError(f"No valid close prices for {ticker}")

    return df


def fetch_symbol_history(symbol: str, timeframe: str) -> Tuple[pd.DataFrame, str]:
    settings = TIMEFRAMES[timeframe]
    errors: List[str] = []

    for ticker in SYMBOL_TICKERS[symbol]:
        try:
            df = fetch_history_for_ticker(
                ticker=ticker,
                interval=settings["interval"],
                period=settings["period"],
            )
            if len(df) < SLOW_MA_PERIOD:
                raise ValueError(
                    f"Only {len(df)} bars returned; need at least {SLOW_MA_PERIOD} bars"
                )
            return df, ticker
        except Exception as exc:  # noqa: BLE001
            errors.append(f"{ticker}: {exc}")
            logger.warning("Data fetch failed for %s %s via %s: %s", symbol, timeframe, ticker, exc)

    joined_errors = " | ".join(errors)
    raise RuntimeError(f"All data sources failed for {symbol} {timeframe}: {joined_errors}")


def calculate_timeframe_signal(symbol: str, timeframe: str) -> TimeframeSignal:
    df, ticker_used = fetch_symbol_history(symbol, timeframe)
    df["fast_ma"] = df["Close"].rolling(window=FAST_MA_PERIOD).mean()
    df["medium_ma"] = df["Close"].rolling(window=MEDIUM_MA_PERIOD).mean()
    df["slow_ma"] = df["Close"].rolling(window=SLOW_MA_PERIOD).mean()

    latest = df.dropna(subset=["fast_ma", "medium_ma", "slow_ma"]).iloc[-1]
    price = float(latest["Close"])
    fast_ma = float(latest["fast_ma"])
    medium_ma = float(latest["medium_ma"])
    slow_ma = float(latest["slow_ma"])

    if fast_ma > medium_ma > slow_ma and price > fast_ma:
        direction = "BUY"
    elif fast_ma < medium_ma < slow_ma and price < fast_ma:
        direction = "SELL"
    else:
        direction = "NEUTRAL"

    bar_index = latest.name
    if hasattr(bar_index, "to_pydatetime"):
        bar_time = bar_index.to_pydatetime().astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    else:
        bar_time = str(bar_index)

    return TimeframeSignal(
        timeframe=timeframe,
        direction=direction,
        price=price,
        fast_ma=fast_ma,
        medium_ma=medium_ma,
        slow_ma=slow_ma,
        bar_time=bar_time,
        ticker_used=ticker_used,
        bars=len(df),
    )


def evaluate_symbol(symbol: str) -> Optional[ConfirmedSignal]:
    timeframe_signals: Dict[str, TimeframeSignal] = {}

    for timeframe in TIMEFRAMES:
        timeframe_signals[timeframe] = calculate_timeframe_signal(symbol, timeframe)

    directions = [sig.direction for sig in timeframe_signals.values()]
    confirmed_direction = directions[0]
    if confirmed_direction not in {"BUY", "SELL"} or any(direction != confirmed_direction for direction in directions):
        return None

    entry_price = timeframe_signals["M1"].price
    point_size = POINT_SIZES[symbol]
    stop_distance = STOP_LOSS_POINTS * point_size
    take_profit_distance = TAKE_PROFIT_POINTS * point_size

    if confirmed_direction == "BUY":
        stop_loss = entry_price - stop_distance
        take_profit = entry_price + take_profit_distance
    else:
        stop_loss = entry_price + stop_distance
        take_profit = entry_price - take_profit_distance

    return ConfirmedSignal(
        symbol=symbol,
        direction=confirmed_direction,
        entry_price=entry_price,
        stop_loss=stop_loss,
        take_profit=take_profit,
        timeframe_signals=timeframe_signals,
        detected_at=datetime.now(timezone.utc),
    )


def signal_key(signal: ConfirmedSignal) -> str:
    """Build a stable de-duplication key for the latest confirmed signal state."""
    m1_time = signal.timeframe_signals["M1"].bar_time
    return f"{signal.symbol}:{signal.direction}:{m1_time}"


def build_signal_message(signal: ConfirmedSignal) -> str:
    direction_icon = "🟢" if signal.direction == "BUY" else "🔴"
    symbol = html.escape(signal.symbol)
    direction = html.escape(signal.direction)

    rows = []
    for timeframe, tf_signal in signal.timeframe_signals.items():
        rows.append(
            f"✅ {timeframe}: {html.escape(tf_signal.direction)} "
            f"| Price {fmt_price(tf_signal.price, signal.symbol)} "
            f"| MA{FAST_MA_PERIOD}/{MEDIUM_MA_PERIOD}/{SLOW_MA_PERIOD}: "
            f"{fmt_price(tf_signal.fast_ma, signal.symbol)} / "
            f"{fmt_price(tf_signal.medium_ma, signal.symbol)} / "
            f"{fmt_price(tf_signal.slow_ma, signal.symbol)}"
        )

    rr = TAKE_PROFIT_POINTS / STOP_LOSS_POINTS if STOP_LOSS_POINTS else 0

    return (
        f"{direction_icon} <b>SHAKE SIGNAL DETECTED</b> {direction_icon}\n\n"
        f"📌 <b>Symbol:</b> {symbol}\n"
        f"📈 <b>Direction:</b> {direction}\n"
        f"🎯 <b>Entry:</b> {fmt_price(signal.entry_price, signal.symbol)}\n"
        f"🛑 <b>Stop Loss:</b> {fmt_price(signal.stop_loss, signal.symbol)} "
        f"({STOP_LOSS_POINTS:g} points)\n"
        f"🏁 <b>Take Profit:</b> {fmt_price(signal.take_profit, signal.symbol)} "
        f"({TAKE_PROFIT_POINTS:g} points, 1:{rr:.1f} RR)\n\n"
        f"⏱ <b>Timeframe confirmation:</b> M1 ✅ | M5 ✅ | M15 ✅\n"
        + "\n".join(rows)
        + "\n\n"
        f"🧮 <b>Risk suggestion:</b> Risk no more than 1% of account equity on this setup. "
        f"Calculate lot/position size from your account balance and the stop-loss distance before entering.\n"
        f"🕒 <b>Detected:</b> {signal.detected_at.strftime('%Y-%m-%d %H:%M:%S UTC')}\n\n"
        f"⚠️ <i>Informational alert only. Verify market conditions, spread, liquidity, and execution before trading.</i>"
    )


def build_status_text() -> str:
    task_running = monitoring_task is not None and not monitoring_task.done()
    status_icon = "🟢" if task_running else "🔴"
    last_check = last_check_time.strftime("%Y-%m-%d %H:%M:%S UTC") if last_check_time else "Never"
    uptime = datetime.now(timezone.utc) - bot_started_at
    uptime_text = str(uptime).split(".")[0]

    return (
        f"{status_icon} <b>SHAKE Bot Status</b>\n\n"
        f"<b>Monitoring:</b> {'Running' if task_running else 'Stopped'}\n"
        f"<b>Symbols:</b> XAUUSD, BTCUSD\n"
        f"<b>Timeframes:</b> M1, M5, M15\n"
        f"<b>Check interval:</b> {CHECK_INTERVAL_SECONDS} seconds\n"
        f"<b>Last check:</b> {html.escape(last_check)}\n"
        f"<b>Summary:</b> {html.escape(last_check_summary)}\n"
        f"<b>Uptime:</b> {html.escape(uptime_text)}"
    )


async def start_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    user_first_name = update.effective_user.first_name if update.effective_user else "Trader"
    message = (
        f"👋 Welcome, {html.escape(user_first_name)}!\n\n"
        f"I am the <b>SHAKE Trading Signal Bot</b>. I monitor <b>XAUUSD</b> and <b>BTCUSD</b> "
        f"on <b>M1, M5, and M15</b> using MA{FAST_MA_PERIOD}, MA{MEDIUM_MA_PERIOD}, and MA{SLOW_MA_PERIOD}.\n\n"
        f"A signal is sent only when all three timeframes confirm the same BUY or SELL setup.\n\n"
        f"Use /status anytime to check whether monitoring is running."
    )
    await update.message.reply_text(message, parse_mode=ParseMode.HTML)


async def status_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    await update.message.reply_text(build_status_text(), parse_mode=ParseMode.HTML)


async def check_market_once(application: Application) -> None:
    global last_check_time, last_check_summary

    logger.info("Starting SHAKE market check")
    detected_count = 0
    errors: List[str] = []

    for symbol in SYMBOL_TICKERS:
        try:
            signal = await asyncio.to_thread(evaluate_symbol, symbol)
            if signal is None:
                logger.info("No confirmed signal for %s", symbol)
                continue

            key = signal_key(signal)
            async with state_lock:
                state = load_state()
                last_sent = state.get("last_sent", {})
                if last_sent.get(signal.symbol) == key:
                    logger.info("Duplicate signal suppressed for %s: %s", signal.symbol, key)
                    continue

                await application.bot.send_message(
                    chat_id=CHAT_ID,
                    text=build_signal_message(signal),
                    parse_mode=ParseMode.HTML,
                    disable_web_page_preview=True,
                )
                last_sent[signal.symbol] = key
                state["last_sent"] = last_sent
                state["updated_at"] = utc_now_text()
                save_state(state)

            detected_count += 1
            logger.info("Sent %s signal for %s", signal.direction, signal.symbol)
        except Exception as exc:  # noqa: BLE001
            logger.exception("Error checking %s: %s", symbol, exc)
            errors.append(f"{symbol}: {exc}")

    last_check_time = datetime.now(timezone.utc)
    if errors:
        last_check_summary = f"Completed with {len(errors)} error(s); signals sent: {detected_count}."
    else:
        last_check_summary = f"Completed successfully; signals sent: {detected_count}."
    logger.info(last_check_summary)


async def monitoring_loop(application: Application) -> None:
    await asyncio.sleep(3)
    logger.info("Monitoring loop started with %s-second interval", CHECK_INTERVAL_SECONDS)

    while True:
        try:
            await check_market_once(application)
        except asyncio.CancelledError:
            logger.info("Monitoring loop cancelled")
            raise
        except Exception as exc:  # noqa: BLE001
            logger.exception("Unexpected monitoring-loop error: %s", exc)
        await asyncio.sleep(CHECK_INTERVAL_SECONDS)


async def post_init(application: Application) -> None:
    global monitoring_task
    monitoring_task = asyncio.create_task(monitoring_loop(application))
    logger.info("Post-init complete; background monitoring task created")


async def post_shutdown(application: Application) -> None:
    global monitoring_task
    if monitoring_task and not monitoring_task.done():
        monitoring_task.cancel()
        try:
            await monitoring_task
        except asyncio.CancelledError:
            pass
    logger.info("Shutdown complete")


def validate_config() -> None:
    missing = []
    if not BOT_TOKEN:
        missing.append("TELEGRAM_BOT_TOKEN")
    if CHAT_ID is None:
        missing.append("TELEGRAM_CHAT_ID")
    if missing:
        raise RuntimeError(f"Missing required configuration: {', '.join(missing)}")

    if CHECK_INTERVAL_SECONDS < 30:
        logger.warning("CHECK_INTERVAL_SECONDS is below 30; free data APIs may rate-limit frequent polling.")


def build_application() -> Application:
    validate_config()
    application = (
        ApplicationBuilder()
        .token(BOT_TOKEN)
        .post_init(post_init)
        .post_shutdown(post_shutdown)
        .build()
    )
    application.add_handler(CommandHandler("start", start_command))
    application.add_handler(CommandHandler("status", status_command))
    return application


def main() -> None:
    logger.info("Starting SHAKE Telegram Signal Bot")
    application = build_application()
    application.run_polling(
        allowed_updates=Update.ALL_TYPES,
        close_loop=False,
        drop_pending_updates=True,
    )


if __name__ == "__main__":
    main()
