import os
import socket

from fastapi import FastAPI

app = FastAPI()


@app.get("/")
def read_root():
    return {
        "hello_from": socket.gethostname(),
        "role": os.environ.get("ROLE", "unknown"),
    }


@app.get("/health")
def health():
    return {"status": "ok"}
