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
- [x] Basic Setup that spawns a listener and accept loop per connection per thread
  - [x] Start: Runs the listener and listens for a new connection 
  - [x] Serve: Serves a single client

Test: Multiple Receive Data Response Tests: 
  - Send 2 600 bytes data. 1200 bytes
  - since we cannot accomodate "1200 bytes" server, should reliable split and send 2 data. 
    - 600 + 600
    - 1000 + 200

Ack Handling:
  - [x] Dropping the already acked messaged
  - [x] Fully Ack scenario
  - [x] Partial Ack scenario - With re-transmission
  - [x] Boundry Ack Scenarios
    - [x] Closed Session

Timeouts:
  - [x] Make the "socket" timeout
  - [x] Re-transmision timeout
    - Add a pending_tx arr
    - Server handling of re-trasnmistted messages
    - [ ] 3s hard total "session" timeout as well for unacked messages
  - [x] Session Expiry Timeout
      - add a field "last_seen_at"
      - Every call to "checkTimeouts" 
      - for every session: check if  now >= last_seen_at
