FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY remote_time_agent ./remote_time_agent
EXPOSE 8001
CMD ["python", "remote_time_agent/agent.py"]
