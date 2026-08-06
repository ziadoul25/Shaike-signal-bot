FROM python:3.11-slim

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-packages \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of the code
COPY . .

# Run the bot
CMD ["python", "shake_bot.py"]
