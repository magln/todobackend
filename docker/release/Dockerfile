FROM magln/todobackend-base:latest
MAINTAINER Mark Chen <magln.jin@gmail.com>

COPY target /wheelhouse

RUN . /appenv/bin/activate && \ 
    pip install --no-index -f /wheelhouse todobackend && \
    rm -rf /wheelhouse
