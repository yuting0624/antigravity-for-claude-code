#!/usr/bin/env bash
exec node "$(cd "$(dirname "$0")/.." && pwd)/server/index.js" --cli "$@"
