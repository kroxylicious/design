# Hot Reload Feature

As of today, any changes to virtual cluster configs (addition/removal/modification) require a full restart of kroxylicious app. This proposal is to add a dynamic reload feature, which will enable operators to modify virtual cluster configurations (add/remove/modify clusters) while **maintaining service availability for unaffected clusters** without the need for full application restarts. This feature will transform Kroxylicious from a **"restart-to-configure"** system to a **"live-reconfiguration"** system

This proposal is structured as a multi-part implementation to ensure clear separation of concerns and manageable development phases.

- Part 1: Configuration Change Detection - This part focuses on monitoring configuration files, parsing changes, and comparing old vs new configurations to identify exactly which virtual clusters need to be restarted. It provides a clean interface that returns structured change operations (additions, removals, modifications) without actually performing any restart operations.

- Part 2: Graceful Virtual Cluster Restart - This part handles the actual restart operations, including graceful connection draining, in-flight message completion, and rollback mechanisms. It takes the change decisions from Part 1 and executes them safely while ensuring minimal service disruption.

# Part 1: Configuration Change Detection Framework

With this framework, kroxylicious will be able to detect config file changes (using standard fileWatcher service) and using various detector interfaces, it will figure out which virtual clusters are added/removed or modified. The list of affected clusters will be then passed on to the Part 2 of this feature, where the clusters would be gracefully restarted (or rollbacked to previous stable state in case of any failures )

POC PR - https://github.com/kroxylicious/kroxylicious/pull/2901

## Core Classes & Structure

1. **ConfigWatcherService** - File system monitoring and configuration loading orchestrator
    - Monitors configuration file changes using Java NIO WatchService
    - Parses YAML configuration files using the existing ConfigParser when changes are detected
    - Provides graceful shutdown of executor services and watch resources
    - Triggers configuration change callbacks asynchronously to initiate the hot-reload process
    - Handles file parsing errors and continues monitoring
        - `KafkaProxy.java` - As this is the entry point to the proxy app, this class will configure the callback which needs to be triggered when there is a config change. This class will also be responsible for setting up the ConfigurationChangeHandler and ConfigWatcherService

```
public final class KafkaProxy implements AutoCloseable {
        .....
  public KafkaProxy(PluginFactoryRegistry pfr, Configuration config, Features features, Path configFilePath) {
        .....
        // Initialize configuration change handler with direct list of detectors
        this.configurationChangeHandler = new ConfigurationChangeHandler(
                List.of(
                        new VirtualClusterChangeDetector(),
                        new FilterChangeDetector()),
                virtualClusterManager);
    }

  ...

  public CompletableFuture<Void> startConfigurationWatcher(Path configFilePath) {
        .....
        this.configWatcherService = new ConfigWatcherService(
                configFilePath,
                this::handleConfigurationChange,
                Duration.ofMillis(500) // 500ms debounce delay
        );

        return configWatcherService.start();
    }
  ...

  public CompletableFuture<Void> stopConfigurationWatcher() {
        if (configWatcherService == null) {
            return CompletableFuture.completedFuture(null);
        }
        return configWatcherService.stop().thenRun(() -> {
            configWatcherService = null;
        });
    }

  private void handleConfigurationChange(Configuration newConfig) {
        try {
            Configuration newValidatedConfig = validate(newConfig, features);
            Configuration oldConfig = this.config;

            // Create models once to avoid excessive logging during change detection
            List<VirtualClusterModel> oldModels = oldConfig.virtualClusterModel(pfr);
            List<VirtualClusterModel> newModels = newValidatedConfig.virtualClusterModel(pfr);
            ConfigurationChangeContext changeContext = new ConfigurationChangeContext(
                    oldConfig, newValidatedConfig, oldModels, newModels);

            // Delegate to the configuration change handler
            configurationChangeHandler.handleConfigurationChange(changeContext)
                    .thenRun(() -> {
                        // Update the stored configuration after successful hot-reload
                        this.config = newValidatedConfig;
                        // Synchronize the virtualClusterModels with the new configuration to ensure consistency
                        this.virtualClusterModels = newModels;
                        LOGGER.info("Configuration and virtual cluster models successfully updated");
                    });
        }
        catch (Exception e) {
            LOGGER.error("Failed to validate or process configuration change", e);
        }
    }
}
```
```
public class ConfigWatcherService {
   ...
   public ConfigWatcherService(Path configFilePath,
                                Consumer<Configuration> onConfigurationChanged) {
     
    }
  ...
   public CompletableFuture<Void> start() {}
   public CompletableFuture<Void> stop() {}

  //There will be more methods which will schedule a FileWatcher on the configpath
  // and trigger the handleConfigurationChange() whenever there is a valid change

  private void handleConfigurationChange() {
    ...
    onConfigurationChanged.accept(newConfiguration);
    ...
  }
  
}
```

2. **ConfigurationChangeHandler** - Orchestrates the entire configuration change process from detection to execution with rollback capability.
    - This handler accepts a list of detector interfaces which run and identify which virtual clusters are affected.
    - Once we get to know the list of clusters that need to be added/removed/restarted, this class will call the VirtualClusterManager methods to perform addition/deletion/restarts (This class will be discussed in part 2)
    - This class also creates an instance of `ConfigurationChangeRollbackTracker`, which tracks what operations are being applied. So in case of any failures, the operations performed can be reversed to previous stable state.
```
public class ConfigurationChangeHandler {
    
    public ConfigurationChangeHandler(List<ChangeDetector> changeDetectors,
                                      VirtualClusterManager virtualClusterManager) {
        this.changeDetectors = List.copyOf(changeDetectors);
        this.virtualClusterManager = virtualClusterManager;
        ...

    /**
     * Main entry point for handling configuration changes.
     */
     public CompletableFuture<Void> handleConfigurationChange(
          ConfigurationChangeContext changeContext) {
      
      // 1. Detect changes using all registered detectors
      ChangeResult changes = detectChanges(changeContext);
      
      if (!changes.hasChanges()) {
          LOGGER.info("No changes detected - hot-reload not needed");
          return CompletableFuture.completedFuture(null);
      }
      
      // 2. Process changes with rollback tracking
      ConfigurationChangeRollbackTracker rollbackTracker = new ConfigurationChangeRollbackTracker();
      
      return processConfigurationChanges(changes, changeContext, rollbackTracker)
              .thenRun(() -> {
                  LOGGER.info("Configuration hot-reload completed successfully - {} operations processed",
                          changes.getTotalOperations());
              })
              .whenComplete((result, throwable) -> {
                  if (throwable != null) {
                      LOGGER.error("Configuration change failed - initiating rollback", throwable);
                      performRollback(rollbackTracker);
                  }
              });
    }

  /**
     * Coordinates multiple change detectors and aggregates their results.
     */
   private ChangeResult detectChanges(ConfigurationChangeContext context) {
        Set<String> allClustersToRemove = new LinkedHashSet<>();
        Set<String> allClustersToAdd = new LinkedHashSet<>();
        Set<String> allClustersToModify = new LinkedHashSet<>();
        
        changeDetectors.forEach(detector -> {
            try {
                ChangeResult detectorResult = detector.detectChanges(context);
                allClustersToRemove.addAll(detectorResult.clustersToRemove());
                allClustersToAdd.addAll(detectorResult.clustersToAdd());
                allClustersToModify.addAll(detectorResult.clustersToModify());
            }
            catch (Exception e) {
                LOGGER.error("Error in change detector '{}': {}", detector.getName(), e.getMessage(), e);
                // Continue with other detectors even if one fails
            }
        });
        
        return new ChangeResult(
                new ArrayList<>(allClustersToRemove),
                new ArrayList<>(allClustersToAdd),
                new ArrayList<>(allClustersToModify));
    }

   /**
     * Processes configuration changes in the correct order: Remove -> Modify -> Add
     */
    private CompletableFuture<Void> processConfigurationChanges(
            ChangeResult changes, 
            ConfigurationChangeContext context,
            ConfigurationChangeRollbackTracker rollbackTracker) {
        
        // Sequential processing using stream.reduce() with CompletableFuture chaining
        CompletableFuture<Void> chain = CompletableFuture.completedFuture(null);

        // All the below operations will happen by calling methods of `VirtualClusterManager`
        // 1. Remove clusters first (to free up ports/resources)
        // 2. Restart modified existing clusters
        // 3. Add new clusters last
        
        return chain;
    }

  /**
     * Performs rollback of all successful operations in reverse order in failure
     */
  private CompletableFuture<Void> performRollback(ConfigurationChangeRollbackTracker tracker) {
    // Rollback in reverse order: Added -> Modified -> Removed
    // Remove clusters that were successfully added
    // Restore clusters that were modified (revert to old configuration)
    // Re-add clusters that were removed
  }

  
}
```

3. **ConfigurationChangeRollbackTracker** - This class maintains a record of all cluster operations (removals, modifications, additions) so they can be reversed if the overall configuration change fails.
```
public class ConfigurationChangeRollbackTracker {
  
    /**
     * Tracks a cluster removal operation.
     */
    public void trackRemoval(String clusterName, VirtualClusterModel removedModel) {}

    /**
     * Tracks a cluster modification operation.
     */
    public void trackModification(String clusterName, VirtualClusterModel originalModel, VirtualClusterModel newModel) {}

    /**
     * Tracks a cluster addition operation.
     */
    public void trackAddition(String clusterName, VirtualClusterModel addedModel) {}
}
```

4. **ChangeDetector (Interface)** - Strategy pattern interface for different types of change detection.
    - Currently we have only have one implementation - `VirtualClusterChangeDetector` which will detect changes in virtual cluster models, in future we can add a detector for filter changes aka `FilterChangeDetector`
    - Provides a consistent API for comparing old vs new configurations via detectChanges()
    - Returns structured ChangeResult objects with specific operations needed
```
public interface ChangeDetector {
    /**
     * Name of this change detector for logging and debugging.
     */
    String getName();
    
    /**
     * Detect configuration changes and return structured change information.
     * @param context The configuration context containing old and new configurations
     * @return ChangeResult containing categorized cluster operations
     */
    ChangeResult detectChanges(ConfigurationChangeContext context);
}
```
```
public class VirtualClusterChangeDetector implements ChangeDetector {
    
    private static final Logger LOGGER = LoggerFactory.getLogger(VirtualClusterChangeDetector.class);
    
    @Override
    public String getName() {
        return "VirtualClusterChangeDetector";
    }
    
    @Override
    public ChangeResult detectChanges(ConfigurationChangeContext context) {
        // Check for modified clusters using equals() comparison
        List<String> modifiedClusters = findModifiedClusters(context);
        
        // Check for new clusters (exist in new but not old)
        List<String> newClusters = findNewClusters(context);
        
        // Check for removed clusters (exist in old but not new)
        List<String> removedClusters = findRemovedClusters(context);
        
        return new ChangeResult(removedClusters, newClusters, modifiedClusters);
    }
```

5. **ConfigurationChangeContext (Record)** - Immutable data container providing context for change detection.
    - Holds old and new Configuration objects for comparison
```
public record ConfigurationChangeContext(
    Configuration oldConfig,
    Configuration newConfig,
    List<VirtualClusterModel> oldModels,
    List<VirtualClusterModel> newModels
) {}
```

6. **ChangeResult (Record)** - Contains lists of cluster names for each operation type (remove/add/modify)
```
public record ChangeResult(
    List<String> clustersToRemove,
    List<String> clustersToAdd, 
    List<String> clustersToModify
) {}
```

## Flow diagram

<img width="2354" height="1394" alt="Image" src="https://github.com/user-attachments/assets/19a7edba-8881-4fa7-98c8-defcdbb132da" />



# Part 2: Graceful Virtual Cluster Restart

Part 2 of the hot-reload implementation focuses on gracefully restarting of virtual clusters. This component receives structured change operations from Part 1 and executes them in a carefully orchestrated sequence: **connection draining → resource deregistration → new resource registration → connection restoration.**

The design emphasizes minimal service disruption by ensuring all in-flight Kafka requests complete before closing connections (or when a timeout is hit).

## Core Classes & Structure

1. **VirtualClusterManager**
    - **What it does** - Acts as the high-level orchestrator for all virtual cluster lifecycle operations during hot-reload. `ConfigurationChangeHandler` calls the `VirtualClusterManager` to restart/add/remove clusters when there is a config change
    - **Key Responsibilities:**
        - **Cluster Addition**: Takes a new `VirtualClusterModel` and brings it online by registering it using `EndpointRegistry`
        - **Cluster Removal**: Safely takes down an existing cluster by first draining all connections gracefully, then deregistering it using EndpointRegistry
        - **Cluster Restart**: Performs a complete cluster reconfiguration by removing the old version and adding the new version with updated settings
        - **Rollback Integration**: Automatically tracks all successful operations so they can be undone if later operations fail
```
public class VirtualClusterManager {
  
    ...  
    public VirtualClusterManager(EndpointRegistry endpointRegistry, 
                                 ConnectionDrainManager connectionDrainManager) {
        this.endpointRegistry = endpointRegistry;
        this.connectionDrainManager = connectionDrainManager;
    }
    
    /**
     * Gracefully removes a virtual cluster by draining connections and deregistering endpoints.
     */
    public CompletableFuture<Void> removeVirtualCluster(String clusterName, 
                                                        List<VirtualClusterModel> oldModels,
                                                        ConfigurationChangeRollbackTracker rollbackTracker) {
        // 1. Find cluster model to remove
        VirtualClusterModel clusterToRemove = findClusterModel(oldModels, clusterName);
        
        // 2. Drain connections gracefully (30s timeout)
        return connectionDrainManager.gracefullyDrainConnections(clusterName, Duration.ofSeconds(30))
                .thenCompose(v -> {
                    // 3. Deregister all gateways from endpoint registry
                    var deregistrationFutures = clusterToRemove.gateways().values().stream()
                            .map(gateway -> endpointRegistry.deregisterVirtualCluster(gateway))
                            .toArray(CompletableFuture[]::new);
                    
                    return CompletableFuture.allOf(deregistrationFutures);
                })
                .thenRun(() -> {
                    // 4. Track removal for potential rollback
                    rollbackTracker.trackRemoval(clusterName, clusterToRemove);
                    LOGGER.info("Successfully removed virtual cluster '{}'", clusterName);
                });
    }
    
    /**
     * Restarts a virtual cluster with new configuration (remove + add).
     */
    public CompletableFuture<Void> restartVirtualCluster(String clusterName, 
                                                         List<VirtualClusterModel> oldModels,
                                                         List<VirtualClusterModel> newModels,
                                                         ConfigurationChangeRollbackTracker rollbackTracker) {
        VirtualClusterModel oldModel = findClusterModel(oldModels, clusterName);
        VirtualClusterModel newModel = findClusterModel(newModels, clusterName);
        
        // Step 1: Remove existing cluster (drain + deregister)
        return removeVirtualCluster(clusterName, oldModels, rollbackTracker)
                .thenCompose(v -> {
                    // Step 2: Add new cluster with updated configuration
                    return addVirtualCluster(clusterName, List.of(newModel), rollbackTracker);
                })
                .thenRun(() -> {
                    // Step 3: Track modification and stop draining
                    rollbackTracker.trackModification(clusterName, oldModel, newModel);
                    connectionDrainManager.stopDraining(clusterName);
                    LOGGER.info("Successfully restarted virtual cluster '{}' with new configuration", clusterName);
                });
    }
    
    /**
     * Adds a new virtual cluster by registering endpoints and enabling connections.
     */
    public CompletableFuture<Void> addVirtualCluster(String clusterName, 
                                                     List<VirtualClusterModel> newModels,
                                                     ConfigurationChangeRollbackTracker rollbackTracker) {
        VirtualClusterModel newModel = findClusterModel(newModels, clusterName);
        
        return registerVirtualCluster(newModel)
                .thenRun(() -> {
                    // Stop draining to allow new connections
                    connectionDrainManager.stopDraining(clusterName);
                    rollbackTracker.trackAddition(clusterName, newModel);
                    LOGGER.info("Successfully added new virtual cluster '{}'", clusterName);
                });
    }
    
    /**
     * Registers all gateways for a virtual cluster with the endpoint registry.
     */
    private CompletableFuture<Void> registerVirtualCluster(VirtualClusterModel model) {
        LOGGER.info("Registering virtual cluster '{}' with {} gateways", 
                   model.getClusterName(), model.gateways().size());
        
        var registrationFutures = model.gateways().values().stream()
                .map(gateway -> endpointRegistry.registerVirtualCluster(gateway))
                .toArray(CompletableFuture[]::new);
        
        return CompletableFuture.allOf(registrationFutures)
                .thenRun(() -> LOGGER.info("Successfully registered virtual cluster '{}' with all gateways", 
                                          model.getClusterName()));
    }
}
```

2. **ConnectionDrainManager**
    - **What it does** - Implements the graceful connection draining strategy during cluster restarts. This is what makes hot-reload "graceful" - it ensures that client requests in progress are completed rather than dropped.
    - **Key Responsibilities:**
        - **Draining Mode Control**: Starts/stops "draining mode" where new connections are rejected but existing ones continue
        - **Backpressure Strategy**: Applies intelligent backpressure by disabling the channel`autoRead` on downstream channels while keeping upstream channels active. This is done so that any “new” client messages are rejected, while the upstream channel is kept open so that the existing inflight requests are delivered to kafka and their response are successfully delivered back to the client.
        - **In-Flight Monitoring**:  Continuously monitors pending Kafka requests and waits for them to complete before closing connections. This is done using `InFlightMessageTracker` class.
    - **Explanation of the draining strategy**
        - **Phase 1: Initiate Draining Mode** - Set cluster to "draining mode" in which any new connection attempts will be rejected. Then we proceed to gracefully closing the connection.
            ```
            public CompletableFuture<Void> gracefullyDrainConnections(String clusterName, Duration totalTimeout) {
                // 1. Get current connection and message state
                int totalConnections = connectionTracker.getTotalConnectionCount(clusterName);
                int totalInFlight = inFlightTracker.getTotalPendingRequestCount(clusterName);
                
                LOGGER.info("Starting graceful drain for cluster '{}' with {} connections and {} in-flight requests ({}s timeout)",
                           clusterName, totalConnections, totalInFlight, totalTimeout.getSeconds());
                
                // 2. Enter draining mode - reject new connections
                return startDraining(clusterName)
                        .thenCompose(v -> {
                            if (totalConnections == 0) {
                                // Fast path: no connections to drain
                                return CompletableFuture.completedFuture(null);
                            } else {
                                // Proceed with connection closure
                                return gracefullyCloseConnections(clusterName, totalTimeout);
                            }
                        });
            }
            
            public CompletableFuture<Void> startDraining(String clusterName) {
                    drainingClusters.put(clusterName, new AtomicBoolean(true));
                    return CompletableFuture.completedFuture(null);
            }
            ```
        - **Phase 2: Apply Backpressure Strategy** - we set `autoRead = false` only on the downstream channel to reject any new client messages. `ConnectionTracker` class tracks which downstream/upstream channels are active for a given cluster name.
            - **Downstream (Client→Proxy)** - `autoRead = false` - Prevents clients from sending NEW  requests while allowing existing requests to complete
            - **Upstream (Proxy→Kafka)** - `autoRead = true` - Allows Kafka responses to flow back to complete pending requests. In-flight request count decreases naturally as responses arrive
                ```
                public CompletableFuture<Void> gracefullyCloseConnections(String clusterName, Duration timeout) {
                    // 1. Get separate channel collections
                    Set<Channel> downstreamChannels = connectionTracker.getDownstreamActiveChannels(clusterName);
                    Set<Channel> upstreamChannels = connectionTracker.getUpstreamActiveChannels(clusterName);
                    
                    // 2. Apply different strategies to different channel types
                    var allCloseFutures = new ArrayList<CompletableFuture<Void>>();
                    
                    // Add downstream channel close futures
                    downstreamChannels.stream()
                            .map(this::disableAutoReadOnDownstreamChannel)
                            .map(channel -> gracefullyCloseChannel(channel, clusterName, timeout, "DOWNSTREAM"))
                            .forEach(allCloseFutures::add);
                
                    // Add upstream channel close futures
                    upstreamChannels.stream()
                            .map(channel -> gracefullyCloseChannel(channel, clusterName, timeout, "UPSTREAM"))
                            .forEach(allCloseFutures::add);
                    
                    return CompletableFuture.allOf(allCloseFutures.toArray(new CompletableFuture[0]));
                }
                
                private Channel disableAutoReadOnDownstreamChannel(Channel downstreamChannel) {
                    try {
                        if (downstreamChannel.isActive()) {
                            // Get the KafkaProxyFrontendHandler from the channel pipeline
                            KafkaProxyFrontendHandler frontendHandler = downstreamChannel.pipeline().get(KafkaProxyFrontendHandler.class);
                            if (frontendHandler != null) {
                                frontendHandler.applyBackpressure();
                                LOGGER.debug("Applied backpressure via frontend handler for channel: L:/{}, R:/{}",
                                        downstreamChannel.localAddress(), downstreamChannel.remoteAddress());
                            }
                            else {
                                LOGGER.debug("Manually applying backpressure for channel: L:/{}, R:/{}",
                                        downstreamChannel.localAddress(), downstreamChannel.remoteAddress());
                                // Fallback to manual method if handler not found
                                downstreamChannel.config().setAutoRead(false);
                            }
                        }
                    }
                    catch (Exception e) {
                        LOGGER.warn("Failed to disable autoRead for downstream channel L:/{}, R:/{} - continuing with drain",
                                downstreamChannel.localAddress(), downstreamChannel.remoteAddress(), e);
                    }
                    return downstreamChannel;
                }
                ```

        - **Phase 3: Monitor In-Flight Message Completion and close channel** - Monitor in-flight count every 100ms for draining while waiting for in-flight count to reach zero naturally. If for some reason, the in-flight count does not reach zero (hangs, could be due to underlying kafka going down), force close after timeout to prevent indefinite hangs. Once in-flight count reaches zero (or after the timeout), close the channel immediately.
           ```
           private CompletableFuture<Void> gracefullyCloseChannel(Channel channel, String clusterName, 
                                                                 String channelType, Duration timeout) {
               CompletableFuture<Void> future = new CompletableFuture<>();
               long startTime = System.currentTimeMillis();
               
               // Schedule timeout
               ScheduledFuture<?> timeoutTask = scheduler.schedule(() -> {
                   if (!future.isDone()) {
                       LOGGER.warn("Graceful shutdown timeout exceeded for {} channel L:/{}, R:/{} in cluster '{}' - forcing immediate closure",
                               channelType, channel.localAddress(), channel.remoteAddress(), clusterName);
                       closeChannelImmediately(channel, future);
                   }
               }, timeoutMillis, TimeUnit.MILLISECONDS);
           
               // Schedule periodic checks for in-flight messages
               ScheduledFuture<?> checkTask = scheduler.scheduleAtFixedRate(() -> {
                 try {
                     if (future.isDone()) {
                         return;
                     }
           
                     int pendingRequests = inFlightTracker.getPendingRequestCount(clusterName, channel);
                     long elapsed = System.currentTimeMillis() - startTime;
           
                     if (pendingRequests == 0) {
                         LOGGER.info("In-flight messages cleared for {} channel L:/{}, R:/{} in cluster '{}' - proceeding with connection closure ({}ms elapsed)",
                                 channelType, channel.localAddress(), channel.remoteAddress(), clusterName, elapsed);
                         closeChannelImmediately(channel, future);
                     }
                     else {
                         // Just wait for existing in-flight messages to complete naturally
                         // Do NOT call channel.read() as it would trigger processing of new messages
                         int totalPending = inFlightTracker.getTotalPendingRequestCount(clusterName);
                         LOGGER.debug("Waiting for {} channel L:/{}, R:/{} in cluster '{}' to drain: {} pending requests (cluster total: {}, {}ms elapsed)",
                                 channelType, channel.localAddress(), channel.remoteAddress(), clusterName, pendingRequests, totalPending, elapsed);
                     }
                 }
                 catch (Exception e) {
                     LOGGER.error("Unexpected error during graceful shutdown monitoring for channel L:/{}, R:/{} in cluster '{}'",
                             channel.localAddress(), channel.remoteAddress(), clusterName, e);
                     future.completeExceptionally(e);
                 }
             }, 50, 100, TimeUnit.MILLISECONDS); // Check every 100ms for faster response
           
             // Cancel scheduled tasks when future completes and log final result
             future.whenComplete((result, throwable) -> {
                 timeoutTask.cancel(false);
                 checkTask.cancel(false);
           
                 if (throwable == null) {
                     LOGGER.info("Successfully completed graceful shutdown of {} channel L:/{}, R:/{} in cluster '{}'",
                             channelType, channel.localAddress(), channel.remoteAddress(), clusterName);
                 }
                 else {
                     LOGGER.error("Graceful shutdown failed for {} channel L:/{}, R:/{} in cluster '{}': {}",
                             channelType, channel.localAddress(), channel.remoteAddress(), clusterName, throwable.getMessage());
                 }
               });
           
               return future;
           }
           
           private void closeChannelImmediately(Channel channel, CompletableFuture<Void> future) {
               if (future.isDone()) {
                   return;
               }
           
               channel.close().addListener(channelFuture -> {
                   if (channelFuture.isSuccess()) {
                       future.complete(null);
                   }
                   else {
                       future.completeExceptionally(channelFuture.cause());
                   }
               });
           }
           ```
    - **How will drain mode reject new client connections ?** - For this, we will put a check in KafkaProxyFrontendHandler#channelActive method to reject new connections, if the particular cluster is in drain mode.
        ```
        public class KafkaProxyFrontendHandler
                extends ChannelInboundHandlerAdapter
                implements NetFilter.NetFilterContext {
            ....
            @Override
            public void channelActive(ChannelHandlerContext ctx) throws Exception {
                this.clientCtx = ctx;
        
                // Check if we should accept this connection (not draining)
                String clusterName = virtualClusterModel.getClusterName();
                if (connectionDrainManager != null && !connectionDrainManager.shouldAcceptConnection(clusterName)) {
                    LOGGER.info("Rejecting new connection for draining cluster '{}'", clusterName);
                    ctx.close();
                    return;
                }
        
                this.proxyChannelStateMachine.onClientActive(this);
                super.channelActive(this.clientCtx);
            }
            ....      
        }
        ```

3. **ConnectionTracker**
    - **What it does** - Maintains real-time inventory of all active network connections per virtual cluster. You can't gracefully drain connections if you don't know what connections exist - this class provides that visibility.
    - **Key Responsibilities:**
        - **Bidirectional Tracking**: Separately tracks downstream connections (client→proxy) and upstream connections (proxy→Kafka)
        - **Channel Management**: Maintains collections of active `Channel` objects for bulk operations like graceful closure
        - **Lifecycle Integration**:  Integrates with `ProxyChannelStateMachine` to automatically track connection establishment and closure
        - **Cleanup Logic**: Automatically removes references to closed channels and cleans up empty cluster entries
```
public class ConnectionTracker {

    // Downstream connections (client → proxy)
    private final Map<String, AtomicInteger> downstreamConnections = new ConcurrentHashMap<>();
    private final Map<String, Set<Channel>> downstreamChannelsByCluster = new ConcurrentHashMap<>();

    // Upstream connections (proxy → target Kafka cluster)
    private final Map<String, AtomicInteger> upstreamConnections = new ConcurrentHashMap<>();
    private final Map<String, Set<Channel>> upstreamChannelsByCluster = new ConcurrentHashMap<>();

    public void onDownstreamConnectionEstablished(String clusterName, Channel channel) {
        downstreamConnections.computeIfAbsent(clusterName, k -> new AtomicInteger(0)).incrementAndGet();
        downstreamChannelsByCluster.computeIfAbsent(clusterName, k -> ConcurrentHashMap.newKeySet()).add(channel);
    }

    public void onDownstreamConnectionClosed(String clusterName, Channel channel) {
        onConnectionClosed(clusterName, channel, downstreamConnections, downstreamChannelsByCluster);
    }


    /**
      Called by ConnectionDrainManager
     */
    public Set<Channel> getDownstreamActiveChannels(String clusterName) {
        Set<Channel> channels = downstreamChannelsByCluster.get(clusterName);
        return channels != null ? Set.copyOf(channels) : Set.of();
    }

    // === UPSTREAM CONNECTION TRACKING ===
    public void onUpstreamConnectionEstablished(String clusterName, Channel channel) {
        upstreamConnections.computeIfAbsent(clusterName, k -> new AtomicInteger(0)).incrementAndGet();
        upstreamChannelsByCluster.computeIfAbsent(clusterName, k -> ConcurrentHashMap.newKeySet()).add(channel);
    }

    public void onUpstreamConnectionClosed(String clusterName, Channel channel) {
        onConnectionClosed(clusterName, channel, upstreamConnections, upstreamChannelsByCluster);
    }

    /**
     Called by ConnectionDrainManager
     */
    public Set<Channel> getUpstreamActiveChannels(String clusterName) {
        Set<Channel> channels = upstreamChannelsByCluster.get(clusterName);
        return channels != null ? Set.copyOf(channels) : Set.of();
    }

    /**
     Called by ConnectionDrainManager
     */
    public int getTotalConnectionCount(String clusterName) {
        return getDownstreamActiveConnectionCount(clusterName) + getUpstreamActiveConnectionCount(clusterName);
    }

    /**
     * Common method to remove a connection and clean up empty entries.
     * This method decrements the connection counter and removes the channel from the set,
     * cleaning up empty entries to prevent memory leaks.
     */
    private void onConnectionClosed(String clusterName, Channel channel,
                                    Map<String, AtomicInteger> connectionCounters,
                                    Map<String, Set<Channel>> channelsByCluster) {
        // Decrement counter and remove if zero or negative
        AtomicInteger counter = connectionCounters.get(clusterName);
        if (counter != null) {
            counter.decrementAndGet();
            if (counter.get() <= 0) {
                connectionCounters.remove(clusterName);
            }
        }

        // Remove channel from set and remove empty sets
        Set<Channel> channels = channelsByCluster.get(clusterName);
        if (channels != null) {
            channels.remove(channel);
            if (channels.isEmpty()) {
                channelsByCluster.remove(clusterName);
            }
        }
    }
}
```

4. **InFlightMessageTracker**
    - **What it does** - Tracks **pending Kafka requests** to ensure no messages are lost during connection closure. This enables the "wait for completion" strategy - connections are only closed after all pending requests have received responses.
    - **Key Responsibilities:**
        - **Request Tracking**: Increments counters when Kafka requests are sent upstream in `ProxyChannelStateMachine`
        - **Response Tracking**: Decrements counters when Kafka responses are received in `ProxyChannelStateMachine`
        - **Channel Cleanup**: Handles cleanup when channels close unexpectedly, adjusting counts appropriately
```
public class InFlightMessageTracker {

    // Map from cluster name to channel to pending request count
    private final Map<String, Map<Channel, AtomicInteger>> pendingRequests = new ConcurrentHashMap<>();

    // Map from cluster name to total pending requests for quick lookup
    private final Map<String, AtomicInteger> totalPendingByCluster = new ConcurrentHashMap<>();

    /**
     * Records that a request has been sent to the upstream cluster.
     *
     * @param clusterName The name of the virtual cluster.
     * @param channel The channel handling the request.
     */
    public void onRequestSent(String clusterName, Channel channel) {
        pendingRequests.computeIfAbsent(clusterName, k -> new ConcurrentHashMap<>())
                .computeIfAbsent(channel, k -> new AtomicInteger(0))
                .incrementAndGet();

        totalPendingByCluster.computeIfAbsent(clusterName, k -> new AtomicInteger(0))
                .incrementAndGet();
    }

    /**
     * Records that a response has been received from the upstream cluster.
     *
     * @param clusterName The name of the virtual cluster.
     * @param channel The channel handling the response.
     */
    public void onResponseReceived(String clusterName, Channel channel) {
        Map<Channel, AtomicInteger> clusterRequests = pendingRequests.get(clusterName);
        if (clusterRequests != null) {
            AtomicInteger channelCounter = clusterRequests.get(channel);
            if (channelCounter != null) {
                int remaining = channelCounter.decrementAndGet();
                if (remaining <= 0) {
                    clusterRequests.remove(channel);
                    if (clusterRequests.isEmpty()) {
                        pendingRequests.remove(clusterName);
                    }
                }

                AtomicInteger totalCounter = totalPendingByCluster.get(clusterName);
                if (totalCounter != null) {
                    int totalRemaining = totalCounter.decrementAndGet();
                    if (totalRemaining <= 0) {
                        totalPendingByCluster.remove(clusterName);
                    }
                }
            }
        }
    }

    /**
     * Records that a channel has been closed, clearing all pending requests for that channel.
     *
     * @param clusterName The name of the virtual cluster.
     * @param channel The channel that was closed.
     */
    public void onChannelClosed(String clusterName, Channel channel) {
        Map<Channel, AtomicInteger> clusterRequests = pendingRequests.get(clusterName);
        if (clusterRequests != null) {
            AtomicInteger channelCounter = clusterRequests.remove(channel);
            if (channelCounter != null) {
                int pendingCount = channelCounter.get();
                if (pendingCount > 0) {
                    // Subtract from total
                    AtomicInteger totalCounter = totalPendingByCluster.get(clusterName);
                    if (totalCounter != null) {
                        int newTotal = totalCounter.addAndGet(-pendingCount);
                        if (newTotal <= 0) {
                            totalPendingByCluster.remove(clusterName);
                        }
                    }
                }
            }

            if (clusterRequests.isEmpty()) {
                pendingRequests.remove(clusterName);
            }
        }
    }

    /**
     * Gets the number of pending requests for a specific channel in a virtual cluster.
     *
     * @param clusterName The name of the virtual cluster.
     * @param channel The channel.
     * @return The number of pending requests.
     */
    public int getPendingRequestCount(String clusterName, Channel channel) {
        Map<Channel, AtomicInteger> clusterRequests = pendingRequests.get(clusterName);
        if (clusterRequests != null) {
            AtomicInteger counter = clusterRequests.get(channel);
            return counter != null ? Math.max(0, counter.get()) : 0;
        }
        return 0;
    }

    /**
     * Gets the total number of pending requests for a virtual cluster across all channels.
     *
     * @param clusterName The name of the virtual cluster.
     * @return The total number of pending requests.
     */
    public int getTotalPendingRequestCount(String clusterName) {
        AtomicInteger counter = totalPendingByCluster.get(clusterName);
        return counter != null ? Math.max(0, counter.get()) : 0;
    }
}
```

5. **Changes in ProxyChannelStateMachine** - We need to enhance the existing state machine for
   - **Connection Lifecycle**: Automatically notifies ConnectionTracker when connections are established/closed
   - **In-flight Message Tracking**: Automatically notifies InFlightMessageTracker when requests/responses flow through

Example code changes for existing ProxyChannelStateMachine methods
```
void messageFromServer(Object msg) {
    // Track responses received from upstream Kafka (completing in-flight requests)
    if (inFlightTracker != null && msg instanceof ResponseFrame && backendHandler != null) {
        inFlightTracker.onResponseReceived(clusterName, backendHandler.serverCtx().channel());
    }

    ....

    // Track responses being sent to client on downstream channel
    if (inFlightTracker != null && msg instanceof ResponseFrame) {
        inFlightTracker.onResponseReceived(clusterName, frontendHandler.clientCtx().channel());
    }
}

void messageFromClient(Object msg) {
    // Track requests being sent upstream (creating in-flight messages)
    if (inFlightTracker != null && msg instanceof RequestFrame && backendHandler != null) {
        inFlightTracker.onRequestSent(clusterName, backendHandler.serverCtx().channel());
    }

    ....
}

void onClientRequest(SaslDecodePredicate dp,
                     Object msg) {
    ....

    // Track requests received from client on downstream channel
    if (inFlightTracker != null && msg instanceof RequestFrame) {
        inFlightTracker.onRequestSent(clusterName, frontendHandler.clientCtx().channel());
    }

    ....
}

void onServerInactive() {
    // Track upstream connection closure
    if (connectionTracker != null && backendHandler != null) {
        connectionTracker.onUpstreamConnectionClosed(clusterName, backendHandler.serverCtx().channel());
    }
    // Clear any pending in-flight messages for this upstream channel
    if (inFlightTracker != null && backendHandler != null) {
        inFlightTracker.onChannelClosed(clusterName, backendHandler.serverCtx().channel());
    }

    ....
}

void onClientInactive() {
    // Track downstream connection closure
    if (connectionTracker != null && frontendHandler != null) {
        connectionTracker.onDownstreamConnectionClosed(clusterName, frontendHandler.clientCtx().channel());
    }
    // Clear any pending in-flight messages for this downstream channel
    if (inFlightTracker != null && frontendHandler != null) {
        inFlightTracker.onChannelClosed(clusterName, frontendHandler.clientCtx().channel());
    }

    ....
}

private void toClientActive(ProxyChannelState.ClientActive clientActive,
                            KafkaProxyFrontendHandler frontendHandler) {
    ....
    // Track downstream connection establishment
    if (connectionTracker != null) {
        connectionTracker.onDownstreamConnectionEstablished(clusterName, frontendHandler.clientCtx().channel());
    }
}

private void toForwarding(Forwarding forwarding) {
    ....
    // Track upstream connection establishment
    if (connectionTracker != null && backendHandler != null) {
        connectionTracker.onUpstreamConnectionEstablished(clusterName, backendHandler.serverCtx().channel());
    }
}
```

# Challenges/Open questions
-  If for some reason, loading of the new cluster configs fails, the code will automatically rollback to the previous state. However this will put the app in such a state that the current config file content does not match with the actual running cluster config.
- What if the rollback fails (for some unforeseen reason), the only way for the operator to know this is via Logs. In such cases, a full app restart might be required.
- If there are multiple gateway nodes running, and if there is failure in few nodes, we may have to introduce some sort of status co-ordinator rather than relying that all instances will behave the same.
