FROM python:3.12-slim

# The version this image reports. The tests build the same code several times with different values,
# which is how they make "a new release" and "a release that never becomes ready".
ARG VERSION=dev
ARG FAIL_READY=0
ENV VERSION=${VERSION} FAIL_READY=${FAIL_READY} PYTHONUNBUFFERED=1

RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app
WORKDIR /app
COPY app/server.py app/loadgen.py ./
USER 10001

EXPOSE 8080
CMD ["python", "server.py"]
