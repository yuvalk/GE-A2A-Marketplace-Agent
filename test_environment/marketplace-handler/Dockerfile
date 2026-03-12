FROM python:3.11-slim
ENV PYTHONUNBUFFERED=1
WORKDIR /app
COPY . .
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt
CMD exec uvicorn marketplace_handler:app --host 0.0.0.0 --port ${PORT:-8080}
