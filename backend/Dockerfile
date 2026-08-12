FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt .
# --force-reinstall: see worker/Dockerfile for why - same shared-container
# Kaniko build order can just as easily let a LATER build in the sequence
# leave stale/partial state for this one; forcing a real reinstall keeps
# this image's layer correct regardless of build order.
RUN pip install --no-cache-dir --force-reinstall -r requirements.txt

COPY app.py .

RUN adduser --disabled-password --gecos "" appuser && \
    chown -R appuser:appuser /app
USER appuser

EXPOSE 5000

# Create tables on startup, then hand off to gunicorn for the actual server.
CMD python -c "import app; app.init_db()" && gunicorn -b 0.0.0.0:5000 app:app
