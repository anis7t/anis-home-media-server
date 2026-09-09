#!/bin/bash
case "$1" in
    start)
        systemctl --user start media-server
        ;;
    stop)
        systemctl --user stop media-server
        ;;
    restart)
        systemctl --user restart media-server
        ;;
    status)
        systemctl --user status media-server
        ;;
    logs)
        journalctl --user -u media-server -f
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs}"
        exit 1
        ;;
esac
