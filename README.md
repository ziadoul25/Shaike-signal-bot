# SHAKE Telegram Signal Bot

**Author:** Manus AI

This project contains a Python Telegram bot that monitors **XAUUSD** and **BTCUSD** every minute and sends Telegram alerts when the **SHAKE strategy** confirms the same directional signal on **M1, M5, and M15**. The bot uses the `python-telegram-bot` package for Telegram command handling and message delivery, and it uses `yfinance` to retrieve market data from Yahoo Finance’s public data endpoints.[1] [2]

> Telegram describes the Bot API as “an HTTP-based interface created for developers keen on building bots for Telegram,” and Bot API requests are made over HTTPS using the bot token.[1]

## Files

| File | Purpose |
| --- | --- |
| `shake_bot.py` | Main long-running bot script with Telegram commands, market-data fetching, SHAKE strategy checks, signal de-duplication, logging, and formatted alerts. |
| `test_telegram.py` | One-off Telegram delivery test script. It sends a simple confirmation message to the configured chat. |
| `check_telegram_bot.py` | Safe credential diagnostic script that calls Telegram `getMe` without printing the token. |
| `validate_market_data.py` | Market-data and strategy-validation helper that checks M1, M5, and M15 retrieval for both symbols. |
| `requirements.txt` | Pip-installable dependencies. |
| `.env` | Local credential and strategy configuration file. This file contains the provided bot token and chat ID and should not be shared. |
| `.env.example` | Safe template showing the required environment variables without secrets. |
| `.gitignore` | Prevents credentials, logs, state files, and caches from being committed. |
| `logs/shake_bot.log` | Runtime log file created automatically after the bot starts. |
| `signal_state.json` | Runtime de-duplication state file created automatically after a signal is sent. |

## Strategy Logic

The bot calculates three moving averages on each monitored timeframe. A signal is only sent when all required timeframes agree. This conservative confirmation rule reduces repeated alerts and prevents single-timeframe noise from triggering signals.

| Component | Value |
| --- | --- |
| Fast Moving Average | 10 periods |
| Medium Moving Average | 25 periods |
| Slow Moving Average | 50 periods |
| Confirmation Timeframes | M1, M5, M15 |
| BUY Rule | Fast MA > Medium MA > Slow MA, and price above Fast MA, on all three timeframes. |
| SELL Rule | Fast MA < Medium MA < Slow MA, and price below Fast MA, on all three timeframes. |
| Check Frequency | Every 60 seconds by default. |

The bot uses Yahoo Finance ticker fallbacks as shown below. The `XAUUSD=X` spot symbol is tried first for gold; if the data source does not return enough bars, the bot falls back to `GC=F`, the gold futures ticker available through Yahoo Finance. Because `yfinance` is an open-source tool that accesses Yahoo’s publicly available APIs and is intended for research and educational purposes, market data should be treated as a free best-effort feed rather than as institutional-grade execution data.[2]

| Bot Symbol | Yahoo Finance Ticker(s) Used |
| --- | --- |
| XAUUSD | `XAUUSD=X`, fallback `GC=F` |
| BTCUSD | `BTC-USD` |

## Signal Message Contents (100 Box Style)

The bot now uses a professional **100 Box** signal format. This includes a boxed header, code-formatted values for easy copying, and a verification hash.

| Field | Behavior |
| --- | --- |
| **Box Style** | Uses Telegram code blocks and bold borders for a professional look. |
| **100 Box Target** | Take Profit is fixed at 100 points (adjustable in `.env`). |
| **Verification Hash** | Signals include the unique verification hash `17f4a3bf...1178`. |
| **Entry Price** | Latest M1 close price used at the time of confirmation. |
| **Stop Loss** | 50 points from entry. |
| **Take Profit** | 100 points from entry. |
| **Risk/Reward** | 1:2 based on 50-point stop and 100-point target. |
| **Duplicate Control** | Suppresses repeated alerts for the same symbol and timeframe. |

## Point-Size Assumptions

The script makes point-size assumptions configurable in `.env`. This is important because “points” can differ by broker and symbol.

| Symbol | Default Point Size | Meaning of 50-Point Stop |
| --- | ---: | ---: |
| XAUUSD | `0.01` | `0.50` price units |
| BTCUSD | `1.0` | `50.00` price units |

If your broker defines gold points differently, edit `XAUUSD_POINT_SIZE` in `.env` before running the bot live.

## Installation

Open a terminal and run the following commands:

```bash
cd /home/ubuntu/shake_bot
python3 -m pip install -r requirements.txt
```

If your environment requires administrator installation, use:

```bash
cd /home/ubuntu/shake_bot
sudo pip3 install -r requirements.txt
```

The dependencies are standard pip packages. `python-telegram-bot` provides the Telegram bot framework, and `yfinance` provides market-data access.[2] [3]

## Configuration

The local `.env` file has already been created in this project directory using the credentials you provided. It follows this structure:

```bash
TELEGRAM_BOT_TOKEN=your_telegram_bot_token_here
TELEGRAM_CHAT_ID=your_telegram_chat_id_here
CHECK_INTERVAL_SECONDS=60
FAST_MA_PERIOD=10
MEDIUM_MA_PERIOD=25
SLOW_MA_PERIOD=50
STOP_LOSS_POINTS=50
TAKE_PROFIT_POINTS=100
XAUUSD_POINT_SIZE=0.01
BTCUSD_POINT_SIZE=1.0
```

Keep `.env` private. A Telegram bot token controls access to the bot, and anyone with the token can potentially send requests to Telegram’s Bot API as that bot.[1]

## Running the Telegram Test

Before running the continuous bot, verify Telegram credentials and delivery:

```bash
cd /home/ubuntu/shake_bot
python3 check_telegram_bot.py
python3 test_telegram.py
```

A successful run prints an HTTP 200 response and sends a confirmation message to the configured Telegram chat. This project was validated successfully with Telegram returning HTTP 200 for both the bot identity check and the delivery test.

## Running the Bot

Start the bot with:

```bash
cd /home/ubuntu/shake_bot
python3 shake_bot.py
```

After startup, the bot listens for Telegram commands and launches a background monitoring loop. Use the following commands in Telegram:

| Command | Response |
| --- | --- |
| `/start` | Sends a welcome message explaining the monitored symbols and strategy. |
| `/status` | Shows whether monitoring is running, the last check time, the check interval, and the latest summary. |

## Running Continuously

This script is designed to run continuously. The current project directory is ready for testing, but a long-running trading bot needs a machine that stays online. The following options are practical:

| Approach | Tradeoffs | Cost | Setup Complexity |
| --- | --- | --- | --- |
| Run on your own computer | Simple and free, but your computer must remain on, connected to the internet, and allowed to keep Python running. | No extra hosting cost. | Low. |
| Run on a cloud server | Best for always-on operation independent of your computer. You can use `systemd`, `tmux`, or another process manager to keep the bot running. | Depends on the server provider. | Moderate. |
| Run in this current working session | Good for quick testing and validation, but not suitable as a permanent host because the session may stop when inactive. | No separate setup. | Low for testing only. |

A simple `systemd` service for a Linux server would look like this:

```ini
[Unit]
Description=SHAKE Telegram Signal Bot
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/home/ubuntu/shake_bot
ExecStart=/usr/bin/python3 /home/ubuntu/shake_bot/shake_bot.py
Restart=always
RestartSec=10
User=ubuntu
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
```

## Logging and Troubleshooting

Runtime logs are written to `logs/shake_bot.log` and also printed to the terminal. If the bot does not send signals, check the log first. Common causes include temporary Yahoo Finance data gaps, insufficient bars for one timeframe, Telegram connectivity errors, or a duplicate signal already being suppressed.

| Issue | Likely Cause | Suggested Action |
| --- | --- | --- |
| No signal messages | Strategy conditions are not confirmed on all three timeframes. | Use `/status` and inspect `logs/shake_bot.log`. |
| XAUUSD data errors | Yahoo Finance may not return enough spot-gold intraday bars. | The bot automatically tries `GC=F` as a fallback. |
| Telegram errors | Bot token, chat ID, or chat permission issue. | Run `python3 test_telegram.py` and check the printed response. |
| Repeated signals not appearing | Duplicate suppression is working. | Remove `signal_state.json` only if you intentionally want to reset duplicate control. |

## Risk Notice

This bot is a technical-alert tool, not a financial adviser. Free market data may be delayed, incomplete, or unavailable. Always verify prices, spreads, session liquidity, and broker execution rules before placing any trade. The included **1% risk suggestion** is a general risk-management reminder, not a position-sizing calculation.

## References

[1]: https://core.telegram.org/bots/api "Telegram Bot API"
[2]: https://ranaroussi.github.io/yfinance/ "yfinance documentation"
[3]: https://docs.python-telegram-bot.org/en/stable/ "python-telegram-bot documentation"
\n\n---\nBuild optimization by Manus AI
