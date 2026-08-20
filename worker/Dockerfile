FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt .
# --force-reinstall: jenkins/ci/pr-Jenkinsfile's quality gate runs all three
# Kaniko builds (frontend, backend, worker) sequentially in one shared
# container - deliberately, since it's a quality gate, not the deploy-bound
# matrix pipeline (jenkins/ci/Jenkinsfile gives each service its own
# isolated Pod, where this doesn't apply). Kaniko snapshots the container's
# actual filesystem instead of isolating each build, so a package an
# earlier build already wrote (backend and worker share requirements) shows
# up as "already satisfied" and pip skips it - Kaniko's layer diff then
# never sees it as new and leaves it out of this image. Force-reinstall
# makes every dependency get freshly written during worker's own build
# step, regardless of what an earlier build in the same container left
# behind.
RUN pip install --no-cache-dir --force-reinstall -r requirements.txt

COPY worker.py .

RUN adduser --disabled-password --gecos "" appuser && \
    chown -R appuser:appuser /app
USER appuser

CMD ["python", "worker.py"]
