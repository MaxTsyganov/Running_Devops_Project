FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt .
# --force-reinstall: CI runs three Kaniko builds (frontend, backend, worker)
# sequentially inside one shared long-lived container - Kaniko snapshots that
# container's actual filesystem rather than isolating each invocation, so a
# package already written by an earlier build in the same container (backend
# and worker share requirements) shows up as "already satisfied" here and
# pip skips writing it, which means Kaniko's layer diff never sees it as new
# and never includes it in THIS image. Forcing a real reinstall makes every
# dependency get freshly written during worker's own build step regardless
# of what a prior build in the same container already left behind.
RUN pip install --no-cache-dir --force-reinstall -r requirements.txt

COPY worker.py .

RUN adduser --disabled-password --gecos "" appuser && \
    chown -R appuser:appuser /app
USER appuser

CMD ["python", "worker.py"]
