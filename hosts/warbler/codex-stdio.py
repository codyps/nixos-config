"""Bridge the app-server JSON-lines transport to its managed Unix WebSocket."""
import sys
import threading

from websockets.exceptions import ConnectionClosed
from websockets.sync.client import unix_connect


def main():
    errors = []
    input_ended = threading.Event()
    # Codex's control socket does not negotiate permessage-deflate.
    with unix_connect(
        sys.argv[1], compression=None, max_size=None, close_timeout=5
    ) as websocket:
        def send_stdin():
            try:
                for line in sys.stdin:
                    if line.strip():
                        websocket.send(line.rstrip("\n"))
                input_ended.set()
            except Exception as error:
                errors.append(error)
            finally:
                websocket.close()

        threading.Thread(target=send_stdin, daemon=True).start()
        try:
            for message in websocket:
                if not isinstance(message, str):
                    raise ValueError("expected a text app-server message")
                print(message, flush=True)
        except ConnectionClosed:
            # Codex may close the socket without echoing the close frame.
            if not input_ended.is_set():
                raise
    if errors:
        raise errors[0]


if __name__ == "__main__":
    main()
