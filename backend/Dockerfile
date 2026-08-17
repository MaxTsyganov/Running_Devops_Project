FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt .
# --force-reinstall: see worker/Dockerfile for the full explanation. Same
# shared-container Kaniko issue - a later build in the sequence can leave
# stale/partial state for this one, so force a real reinstall to keep this
# image's layers correct regardless of build order.
RUN pip install --no-cache-dir --force-reinstall -r requirements.txt

COPY app.py .

RUN adduser --disabled-password --gecos "" appuser && \
    chown -R appuser:appuser /app
USER appuser

EXPOSE 5000

# Create tables on startup, then hand off to gunicorn for the actual server.
CMD python -c "import app; app.init_db()" && gunicorn -b 0.0.0.0:5000 app:app
