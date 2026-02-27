# Frontend Handler Refactoring & Client Session Context

Refactor the frontend handler architecture to improve separation of concerns, introduce a centralized session context, fix the HAProxy message memory leak, and simplify the state machine by eliminating unnecessary states.

## Current situation

### KafkaProxyFrontendHandler Responsibilities

The `KafkaProxyFrontendHandler` currently installs filters and starts working as tail-handler for inbound pipeline processing.

### FilterContext has everything but initialised inside FilterHandler

- FilterContext is initialised late in lifecycle and holds lot of information which is relevant pre and post filter processing.
Session-level information is spread across multiple locations:
- `haProxyMessage` is carried through state records (`HaProxy` → `ApiVersions` → `SelectingServer` → `Connecting` → `Forwarding`)
- `sniHostname`, `clientSoftwareName`, `clientSubjectManager` are passed individually to `FilterHandler`

### HAProxy message memory leak

`HAProxyMessage` implements Netty's `ReferenceCounted` interface but is never released. The message is intercepted in `HAProxyMessageHandler`, passed to the state machine, stored in state records, but never has `release()` called. This causes a memory leak.

## Motivation

### Separation of concerns

The current `KafkaProxyFrontendHandler` violates the single responsibility principle. Splitting responsibilities will make the code easier to understand, test, and maintain.

### Centralized session context

Having a single `ClientSession` object as the source of truth for session data will:
- Simplify parameter passing to components like `FilterHandler` and `FilterContext`
- Make it easier to add new session-level attributes in the future
- Provide a natural place for filters to access connection metadata (HAProxy info, SNI hostname, etc.)

### Memory leak fix

The HAProxy memory leak must be fixed. By extracting data into a plain `HaProxyInfo` record and releasing the original message immediately, we eliminate the leak and avoid carrying `ReferenceCounted` objects through the session lifecycle.

### Clearer pipeline structure

Restructuring the pipeline with a `TailHandler` at the end of the filter chain will:
- Make message flow more intuitive (left-to-right matches logical flow)
- Clearly identify where post-filter routing occurs
- Separate the concerns of "receiving from Netty" and "forwarding to backend"

### Simplified state machine

Eliminating the `HaProxy` state and removing session data from state records will simplify the state machine, making state transitions clearer and reducing the amount of data threaded through transitions.

## Proposal

### Introduce ClientSession as centralized session context

Create a `ClientSession` class to hold all session-level information:

```java
public class ClientSession {
    private final String sessionId;
    private final VirtualClusterModel virtualClusterModel;
    private final EndpointBinding endpointBinding;
    
    // Connection metadata (set during session lifecycle)
    private @Nullable HaProxyInfo haProxyInfo;
    private @Nullable String sniHostname;
    private @Nullable String clientSoftwareName;
    private @Nullable String clientSoftwareVersion;
    
    // Session components
    private final ClientSubjectManager clientSubjectManager;
    
    // Getters and setters
}
```

Create a plain `HaProxyInfo` record to hold extracted HAProxy data:

```java
public record HaProxyInfo(
    @Nullable String sourceAddress,
    int sourcePort,
    @Nullable String destinationAddress,
    int destinationPort
) {
    public static HaProxyInfo fromMessage(HAProxyMessage message) {
        return new HaProxyInfo(
            message.sourceAddress(),
            message.sourcePort(),
            message.destinationAddress(),
            message.destinationPort()
        );
    }
}
```

### Restructure pipeline with TailHandler

Change the pipeline structure from:

```
[Decoders] → [FilterHandler-1] → [FilterHandler-N] → [FrontendHandler]
```

To:

```
[Decoders] → [FrontendHandler] → [FilterHandler-1] → [FilterHandler-N] → [TailHandler]
```

#### Component responsibilities after refactoring

| Component | Responsibility |
|-----------|----------------|
| `KafkaProxyFrontendHandler` | Netty I/O events, session setup, pipeline construction |
| `FilterHandler` | Message transformation (unchanged) |
| `TailHandler` | Post-filter routing to backend, inject server responses into filter chain |

#### TailHandler implementation

```java
public class TailHandler extends ChannelInboundHandlerAdapter {
    
    private final ProxyChannelStateMachine stateMachine;
    
    // Inbound: receives client requests after all filters have processed
    @Override
    public void channelRead(ChannelHandlerContext ctx, Object msg) {
        stateMachine.messageFromClient(msg);
    }
    
    // Called by backend/state machine to inject server responses into filter chain
    public void forwardToClient(Object msg) {
        // flows backward through filters
    }
    
    // Buffering logic for pre-connection messages
    // Flush coordination
}
```

#### Message flow after refactoring

```
Inbound (Client → Server):
[Decoder] → [FrontendHandler] → [Filter-1] → [Filter-N] → [TailHandler] → StateMachine → [Backend]

Outbound (Server → Client):
[Backend] → StateMachine → TailHandler.writeResponseToClient() → [Filter-N] → [Filter-1] → [Encoder]
```

### Fix HAProxy memory leak and eliminate HaProxy state

Extract HAProxy data and release immediately in `HAProxyMessageHandler`:

```java
// In HAProxyMessageHandler.channelRead()
if (msg instanceof HAProxyMessage haProxyMessage) {
    try {
        clientSession.setHaProxyInfo(HaProxyInfo.fromMessage(haProxyMessage));
    } finally {
        haProxyMessage.release();
    }
    // No state machine notification needed — data stored in ClientSession
}
```

Remove the `HaProxy` state from `ProxyChannelState`. The state transitions simplify from:

```
ClientActive → HaProxy → ApiVersions → SelectingServer → Connecting → Forwarding
         ↘            ↗
          → ApiVersions
         ↘
          → SelectingServer
```

To:

```
ClientActive → ApiVersions → SelectingServer → Connecting → Forwarding
         ↘                ↗
          → SelectingServer
```

### Simplify state records

With `ClientSession` holding session data, state records become minimal:

Before:
```java
record SelectingServer(
    @Nullable HAProxyMessage haProxyMessage,
    @Nullable String clientSoftwareName,
    @Nullable String clientSoftwareVersion
) { }
```

After:
```java
record SelectingServer() { }
// Session data accessed via ClientSession
```

### Architecture after refactoring

```
                                    ┌─────────────────┐
                                    │  ClientSession  │
                                    │  - sessionId    │
                                    │  - haProxyInfo  │
                                    │  - sniHostname  │
                                    │  - clientSw*    │
                                    │  - subjectMgr   │
                                    └────────┬────────┘
                                             │
              ┌──────────────────────────────┼──────────────────────────────┐
              │                              │                              │
              ▼                              ▼                              ▼
┌─────────────────────────┐    ┌─────────────────────────┐    ┌─────────────────────────┐
│  KafkaProxyFrontend     │    │  ProxyChannelState      │    │      TailHandler        │
│       Handler           │    │       Machine           │    │                         │
│                         │    │                         │    │  - Post-filter routing  │
│  - Netty I/O events     │───▶│  - State transitions    │◀───│  - Buffering            │
│  - Pipeline setup       │    │  - Lifecycle callbacks  │───▶│  - Response injection   │
│  - Session init         │    │                         │    │                         │
└─────────────────────────┘    └─────────────────────────┘    └─────────────────────────┘
                                             │
                                             ▼
                               ┌─────────────────────────┐
                               │  KafkaProxyBackend      │
                               │       Handler           │
                               └─────────────────────────┘
```
