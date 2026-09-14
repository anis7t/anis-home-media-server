import os

from waitress import serve

from app import app, initialize_runtime


if __name__ == "__main__":
    initialize_runtime()

    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", "8000"))
    threads = int(os.environ.get("WAITRESS_THREADS", "8"))

    print(
        f"Starting Media Server production server on "
        f"{host}:{port} with {threads} threads..."
    )

    serve(
        app,
        host=host,
        port=port,
        threads=threads,
        ident="media-server",
    )