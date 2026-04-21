Notes:
- connection-oriented byte stream protocol
- Runs on top of UDP
- out-out-order UDP packets into pair of reliable and in-order byte streams
- per-session payload length counter on each side

Paths:
- /connect/[session]
- /data/[session]/[pos]/[data]
- /ack/[session]/[length]
- /close/[session]

TODO:

Listener Support:
- [ ] Basic Setup that spawns a listener and accept loop per connection per thread
  - [ ] Start: Runs the listener and listens for a new connection 
  - [ ] Serve: Serves a single client
