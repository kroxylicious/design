# Hot Reload Feature - HTTP-Based Approach

As of today, any changes to virtual cluster configs (addition/removal/modification) require a full restart of Kroxylicious app.
This proposal describes the dynamic reload feature, which enables operators to modify virtual cluster configurations (add/remove/modify clusters) while **maintaining service availability for unaffected clusters** without the need for full application restarts.
This feature transforms Kroxylicious from a **"restart-to-configure"** system to a **"live-reconfiguration"** system.

## HTTP-Based vs File Watcher Approach

The original proposal used a file-based watcher mechanism to detect configuration changes. This has been replaced with an **HTTP-based trigger mechanism** for the following reasons:

| Aspect | File Watcher | HTTP Endpoint |
|--------|--------------|---------------|
| **Trigger** | Automatic on file change | Explicit HTTP POST request |
| **Control** | Passive monitoring | Active, operator-controlled |
| **Configuration Delivery** | Read from filesystem | Sent in request body |
| **Response** | Asynchronous (via logs) | Synchronous HTTP response |
| **Validation** | After file is saved | Before applying changes |
| **Rollback** | Manual file restore | Automatic on failure |

This proposal is structured as a multi-part implementation to ensure clear separation of concerns:

- **Part 1: HTTP-Based Configuration Reload Endpoint** - This part focuses on the HTTP endpoint that receives new configurations, validates them, and triggers the hot-reload process. It provides synchronous feedback via HTTP response with detailed reload results.

- **Part 2: Graceful Virtual Cluster Restart** - This part handles the actual restart operations, including graceful connection draining, in-flight message completion, and rollback mechanisms. It takes the change decisions from Part 1 and executes them safely while ensuring minimal service disruption.

**POC PR** - https://github.com/kroxylicious/kroxylicious/pull/3176
---

# Part 1: HTTP-Based Configuration Reload Endpoint

With this framework, operators can trigger configuration reloads by sending an HTTP POST request to `/admin/config/reload` with the new YAML configuration in the request body. The endpoint validates the configuration, detects changes, and orchestrates the reload process with full rollback support.

## Endpoint Configuration

To enable the reload endpoint, add the following to your kroxylicious configuration:

```yaml
management:
  endpoints:
    prometheus: {}
    configReload:
      enabled: true
      timeout: 60s  # Optional, defaults to 60s
```

## HTTP API

**Endpoint:** `POST /admin/config/reload`

**Request:**
- **Method:** POST
- **Content-Type:** `application/yaml`, `text/yaml`, or `application/x-yaml`
- **Body:** Complete YAML configuration

**Response:**
- **Content-Type:** `application/json`
- **Status:** 200 OK (success), 400 Bad Request (validation error), 409 Conflict (concurrent reload), 500 Internal Server Error (failure)

**Example Response (Success):**
```json
{
  "success": true,
  "message": "Configuration reloaded successfully",
  "clustersModified": 1,
  "clustersAdded": 0,
  "clustersRemoved": 0,
  "timestamp": "2024-01-15T10:30:00Z"
}
```

**Example Response (Failure):**
```json
{
  "success": false,
  "message": "Configuration validation failed: invalid bootstrap servers",
  "clustersModified": 0,
  "clustersAdded": 0,
  "clustersRemoved": 0,
  "timestamp": "2024-01-15T10:30:00Z"
}
```

> **WARNING:** This endpoint has NO authentication and is INSECURE by design. Use network policies or firewalls to restrict access.

## Core Classes & Structure

### 1. ConfigurationReloadEndpoint

HTTP POST endpoint handler for triggering configuration reload at `/admin/config/reload`.

- **What it does**: Receives HTTP POST requests containing YAML configuration and initiates the reload process
- **Key Responsibilities:**
    - Extracts the YAML configuration from the HTTP request body
    - Delegates request processing to `ReloadRequestProcessor`
    - Formats successful responses using `ResponseFormatter`
    - Handles different exception types and returns appropriate HTTP status codes:
        - `400 Bad Request` for validation errors (invalid YAML, wrong content-type)
        - `409 Conflict` for concurrent reload attempts
        - `500 Internal Server Error` for reload failures
    - Provides structured JSON response with reload results

```java
public class ConfigurationReloadEndpoint implements Function<HttpRequest, HttpResponse> {

    public static final String PATH = "/admin/config/reload";

    private final ReloadRequestProcessor requestProcessor;
    private final ResponseFormatter responseFormatter;

    public ConfigurationReloadEndpoint(
                                      ReloadRequestProcessor requestProcessor,
                                      ResponseFormatter responseFormatter) {
        this.requestProcessor = Objects.requireNonNull(requestProcessor);
        this.responseFormatter = Objects.requireNonNull(responseFormatter);
    }

    @Override
    public HttpResponse apply(HttpRequest request) {
        try {
            // Create context from request
            ReloadRequestContext context = ReloadRequestContext.from(request);

            // Process request through handler chain
            ReloadResponse response = requestProcessor.process(context);

            // Format and return response
            return responseFormatter.format(response, request);
        }
        catch (ValidationException e) {
            return createErrorResponse(request, HttpResponseStatus.BAD_REQUEST, e.getMessage());
        }
        catch (ConcurrentReloadException e) {
            return createErrorResponse(request, HttpResponseStatus.CONFLICT, e.getMessage());
        }
        catch (ReloadException e) {
            return createErrorResponse(request, HttpResponseStatus.INTERNAL_SERVER_ERROR, e.getMessage());
        }
    }
}
```

### 2. ReloadRequestProcessor

Processes reload requests using the **Chain of Responsibility** pattern. Each handler performs a specific task and passes the context to the next handler.

- **What it does**: Orchestrates the request processing pipeline by chaining multiple handlers that validate, parse, and execute the reload
- **Key Responsibilities:**
    - Builds the handler chain in the correct order: validation → parsing → execution
    - Passes an immutable `ReloadRequestContext` through each handler
    - Each handler can enrich the context (e.g., add parsed Configuration) or throw exceptions
    - Returns the final `ReloadResponse` from the context after all handlers complete
    - Enforces maximum content length (10MB) to prevent memory exhaustion

```java
public class ReloadRequestProcessor {

    private static final int MAX_CONTENT_LENGTH = 10 * 1024 * 1024; // 10MB

    private final List<ReloadRequestHandler> handlers;

    public ReloadRequestProcessor(
                                  ConfigParser parser,
                                  ConfigurationReloadOrchestrator orchestrator,
                                  long timeoutSeconds) {
        this.handlers = List.of(
                new ContentTypeValidationHandler(),      // 1. Validates Content-Type header
                new ContentLengthValidationHandler(MAX_CONTENT_LENGTH), // 2. Validates body size
                new ConfigurationParsingHandler(parser), // 3. Parses YAML to Configuration
                new ConfigurationReloadHandler(orchestrator, timeoutSeconds)); // 4. Executes reload
    }

    public ReloadResponse process(ReloadRequestContext context) throws ReloadException {
        ReloadRequestContext currentContext = context;

        for (ReloadRequestHandler handler : handlers) {
            currentContext = handler.handle(currentContext);
        }

        return currentContext.getResponse();
    }
}
```

**Handler Chain:**

```
┌─────────────────────────────────┐
│ ContentTypeValidationHandler    │ Validates Content-Type: application/yaml
└───────────────┬─────────────────┘
                │
                ▼
┌─────────────────────────────────┐
│ ContentLengthValidationHandler  │ Validates body size <= 10MB
└───────────────┬─────────────────┘
                │
                ▼
┌─────────────────────────────────┐
│ ConfigurationParsingHandler     │ Parses YAML → Configuration object
└───────────────┬─────────────────┘
                │
                ▼
┌─────────────────────────────────┐
│ ConfigurationReloadHandler      │ Executes reload via orchestrator
└─────────────────────────────────┘
```

### 3. ReloadRequestContext

Immutable context object passed through the request processing chain. Uses the builder pattern for creating modified contexts.

- **What it does**: Carries request data and processing results through the handler chain without mutation
- **Key Responsibilities:**
    - Holds the original `HttpRequest` and extracted request body
    - Stores the parsed `Configuration` after parsing handler completes
    - Stores the final `ReloadResponse` after reload handler completes
    - Provides immutable "with" methods that return new context instances with updated fields
    - Uses `Builder` pattern for clean construction and modification

```java
public class ReloadRequestContext {

    private final HttpRequest httpRequest;
    private final String requestBody;
    private final Configuration parsedConfiguration;
    private final ReloadResponse response;

    public static ReloadRequestContext from(HttpRequest request) {
        String body = null;
        if (request instanceof FullHttpRequest fullRequest) {
            ByteBuf content = fullRequest.content();
            if (content.readableBytes() > 0) {
                body = content.toString(StandardCharsets.UTF_8);
            }
        }

        return new Builder()
                .withHttpRequest(request)
                .withRequestBody(body)
                .build();
    }

    // Immutable "with" methods return new context instances
    public ReloadRequestContext withParsedConfiguration(Configuration config) {
        return new Builder(this).withParsedConfiguration(config).build();
    }

    public ReloadRequestContext withResponse(ReloadResponse response) {
        return new Builder(this).withResponse(response).build();
    }
}
```

### 4. ConfigurationReloadOrchestrator

Orchestrates configuration reload operations with **concurrency control**, **validation**, and **state tracking**. Uses `ReentrantLock` to prevent concurrent reloads.

- **What it does**: Acts as the main coordinator for the entire reload workflow, from validation through execution to state management
- **Key Responsibilities:**
    - **Concurrency Control**: Uses `ReentrantLock.tryLock()` to prevent concurrent reloads and returns `ConcurrentReloadException` if a reload is already in progress
    - **Configuration Validation**: Validates the new configuration using the `Features` framework before applying
    - **FilterChainFactory Management**: Creates a new `FilterChainFactory` with updated filter definitions and performs atomic swap on success
    - **Rollback on Failure**: If reload fails, closes the new factory and keeps the old factory active
    - **State Tracking**: Maintains reload state (IDLE/IN_PROGRESS) via `ReloadStateManager`
    - **Disk Persistence**: Persists successful configuration to disk by replacing the existing config file with the new one. A backup of the old config is also taken (.bak extension)

```java
public class ConfigurationReloadOrchestrator {

    private final ConfigurationChangeHandler configurationChangeHandler;
    private final PluginFactoryRegistry pluginFactoryRegistry;
    private final Features features;
    private final ReloadStateManager stateManager;
    private final ReentrantLock reloadLock;

    private Configuration currentConfiguration;
    private final @Nullable Path configFilePath;

    // Shared mutable reference to FilterChainFactory - enables atomic swaps during hot reload
    private final AtomicReference<FilterChainFactory> filterChainFactoryRef;

    public ConfigurationReloadOrchestrator(
            Configuration initialConfiguration,
            ConfigurationChangeHandler configurationChangeHandler,
            PluginFactoryRegistry pluginFactoryRegistry,
            Features features,
            @Nullable Path configFilePath,
            AtomicReference<FilterChainFactory> filterChainFactoryRef) {
        this.currentConfiguration = Objects.requireNonNull(initialConfiguration);
        this.configurationChangeHandler = Objects.requireNonNull(configurationChangeHandler);
        this.pluginFactoryRegistry = Objects.requireNonNull(pluginFactoryRegistry);
        this.features = Objects.requireNonNull(features);
        this.filterChainFactoryRef = Objects.requireNonNull(filterChainFactoryRef);
        this.configFilePath = configFilePath;
        this.stateManager = new ReloadStateManager();
        this.reloadLock = new ReentrantLock();
    }

    /**
     * Reload configuration with concurrency control.
     * This method implements the Template Method pattern - it defines the reload algorithm
     * skeleton with fixed steps.
     */
    public CompletableFuture<ReloadResult> reload(Configuration newConfig) {
        // 1. Check if reload already in progress
        if (!reloadLock.tryLock()) {
            return CompletableFuture.failedFuture(
                new ConcurrentReloadException("A reload operation is already in progress"));
        }

        Instant startTime = Instant.now();

        try {
            // 2. Mark reload as started
            stateManager.startReload();

            // 3. Validate configuration
            Configuration validatedConfig = validateConfiguration(newConfig);

            // 4. Execute reload
            return executeReload(validatedConfig, startTime)
                    .whenComplete((result, error) -> {
                        if (error != null) {
                            stateManager.recordFailure(error);
                        }
                        else {
                            stateManager.recordSuccess(result);
                            this.currentConfiguration = validatedConfig;
                            persistConfigurationToDisk(validatedConfig);
                        }
                    });
        }
        finally {
            reloadLock.unlock();
        }
    }

    /**
     * Execute the configuration reload by creating a new FilterChainFactory,
     * building a change context, and delegating to ConfigurationChangeHandler.
     */
    private CompletableFuture<ReloadResult> executeReload(Configuration newConfig, Instant startTime) {
        // 1. Create new FilterChainFactory with updated filter definitions
        FilterChainFactory newFactory = new FilterChainFactory(pluginFactoryRegistry, newConfig.filterDefinitions());

        // 2. Get old factory for rollback capability
        FilterChainFactory oldFactory = filterChainFactoryRef.get();

        // 3. Build change context with both old and new factories
        List<VirtualClusterModel> oldModels = currentConfiguration.virtualClusterModel(pluginFactoryRegistry);
        List<VirtualClusterModel> newModels = newConfig.virtualClusterModel(pluginFactoryRegistry);

        ConfigurationChangeContext changeContext = new ConfigurationChangeContext(
                currentConfiguration, newConfig,
                oldModels, newModels,
                oldFactory, newFactory);

        // 4. Execute configuration changes
        return configurationChangeHandler.handleConfigurationChange(changeContext)
                .thenApply(v -> {
                    // SUCCESS: Atomically swap to new factory
                    filterChainFactoryRef.set(newFactory);
                    if (oldFactory != null) {
                        oldFactory.close();
                    }
                    return buildReloadResult(changeContext, startTime);
                })
                .exceptionally(error -> {
                    // FAILURE: Rollback - close new factory, keep old factory
                    newFactory.close();
                    throw new CompletionException("Configuration reload failed", error);
                });
    }
}
```

### 5. ConfigurationChangeHandler

Orchestrates the entire configuration change process from detection to execution with rollback capability.

- **What it does**: Coordinates multiple change detectors, aggregates their results, and executes cluster operations in the correct order
- **Key Responsibilities:**
    - **Detector Coordination**: Accepts a list of `ChangeDetector` implementations and runs all of them to identify changes
    - **Result Aggregation**: Uses `LinkedHashSet` to merge results from all detectors, removing duplicates while maintaining order
    - **Ordered Execution**: Processes changes in the correct order: Remove → Modify → Add (to free up ports/resources first)
    - **Rollback Tracking**: Creates a `ConfigurationChangeRollbackTracker` to track all successful operations for potential rollback
    - **Rollback on Failure**: If any operation fails, initiates rollback of all previously successful operations in reverse order

```java
public class ConfigurationChangeHandler {

    private final List<ChangeDetector> changeDetectors;
    private final VirtualClusterManager virtualClusterManager;

    public ConfigurationChangeHandler(List<ChangeDetector> changeDetectors,
                                      VirtualClusterManager virtualClusterManager) {
        this.changeDetectors = List.copyOf(changeDetectors);
        this.virtualClusterManager = virtualClusterManager;
    }

    /**
     * Main entry point for handling configuration changes.
     */
    public CompletableFuture<Void> handleConfigurationChange(ConfigurationChangeContext changeContext) {
        // 1. Detect changes using all registered detectors
        ChangeResult changes = detectChanges(changeContext);

        if (!changes.hasChanges()) {
            LOGGER.info("No changes detected - hot-reload not needed");
            return CompletableFuture.completedFuture(null);
        }

        // 2. Process changes with rollback tracking
        ConfigurationChangeRollbackTracker rollbackTracker = new ConfigurationChangeRollbackTracker();

        return processConfigurationChanges(changes, changeContext, rollbackTracker)
                .whenComplete((result, throwable) -> {
                    if (throwable != null) {
                        LOGGER.error("Configuration change failed - initiating rollback", throwable);
                        performRollback(rollbackTracker);
                    }
                    else {
                        LOGGER.info("Configuration hot-reload completed successfully - {} operations processed",
                                changes.getTotalOperations());
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
            }
        });

        return new ChangeResult(
                new ArrayList<>(allClustersToRemove),
                new ArrayList<>(allClustersToAdd),
                new ArrayList<>(allClustersToModify));
    }

    /**
     * Processes configuration changes in the correct order: Remove → Modify → Add
     */
    private CompletableFuture<Void> processConfigurationChanges(
            ChangeResult changes,
            ConfigurationChangeContext context,
            ConfigurationChangeRollbackTracker rollbackTracker) {

        CompletableFuture<Void> chain = CompletableFuture.completedFuture(null);

        // 1. Remove clusters first (to free up ports/resources)
        // 2. Restart modified existing clusters
        // 3. Add new clusters last

        return chain;
    }
}
```

### 6. ChangeDetector Interface

Strategy pattern interface for different types of change detection.

- **What it does**: Defines a contract for components that detect specific types of configuration changes
- **Key Responsibilities:**
    - Provides a consistent API for comparing old vs new configurations via `detectChanges()`
    - Returns structured `ChangeResult` objects with specific operations needed (add/remove/modify)
    - Enables extensibility - new detectors can be added without modifying existing code
    - Currently has two implementations: `VirtualClusterChangeDetector` and `FilterChangeDetector`

```java
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

### 7. VirtualClusterChangeDetector

Identifies virtual clusters needing restart due to model changes (new, removed, modified).

- **What it does**: Compares old and new `VirtualClusterModel` collections to detect cluster-level changes
- **Key Responsibilities:**
    - **New Cluster Detection**: Finds clusters that exist in new configuration but not in old (additions)
    - **Removed Cluster Detection**: Finds clusters that exist in old configuration but not in new (deletions)
    - **Modified Cluster Detection**: Finds clusters that exist in both but have different `VirtualClusterModel` (using `equals()` comparison)
    - Uses cluster name as the unique identifier for comparison

```java
public class VirtualClusterChangeDetector implements ChangeDetector {

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

    private List<String> findModifiedClusters(ConfigurationChangeContext context) {
        Map<String, VirtualClusterModel> oldModelMap = context.oldModels().stream()
                .collect(Collectors.toMap(VirtualClusterModel::getClusterName, model -> model));

        return context.newModels().stream()
                .filter(newModel -> {
                    VirtualClusterModel oldModel = oldModelMap.get(newModel.getClusterName());
                    return oldModel != null && !oldModel.equals(newModel);
                })
                .map(VirtualClusterModel::getClusterName)
                .collect(Collectors.toList());
    }

    private List<String> findNewClusters(ConfigurationChangeContext context) {
        Set<String> oldClusterNames = context.oldModels().stream()
                .map(VirtualClusterModel::getClusterName)
                .collect(Collectors.toSet());

        return context.newModels().stream()
                .map(VirtualClusterModel::getClusterName)
                .filter(name -> !oldClusterNames.contains(name))
                .collect(Collectors.toList());
    }

    private List<String> findRemovedClusters(ConfigurationChangeContext context) {
        Set<String> newClusterNames = context.newModels().stream()
                .map(VirtualClusterModel::getClusterName)
                .collect(Collectors.toSet());

        return context.oldModels().stream()
                .map(VirtualClusterModel::getClusterName)
                .filter(name -> !newClusterNames.contains(name))
                .collect(Collectors.toList());
    }
}
```

### 8. FilterChangeDetector

Identifies clusters needing restart due to filter configuration changes.

- **What it does**: Detects changes in filter definitions and identifies which virtual clusters are affected
- **Key Responsibilities:**
    - **Filter Definition Changes**: Compares `NamedFilterDefinition` objects to find filters where type or config changed (additions/removals are handled by Configuration validation)
    - **Default Filters Changes**: Detects changes to the `defaultFilters` list (order matters for filter chain execution)
    - Returns only `clustersToModify` - filter changes don't cause cluster additions/removals
- **Cluster Impact Rules**: A cluster is impacted if:
    - It uses a filter definition that was modified (either from explicit filters or defaults), OR
    - It doesn't specify `cluster.filters()` AND the `defaultFilters` list changed

```java
public class FilterChangeDetector implements ChangeDetector {

    @Override
    public String getName() {
        return "FilterChangeDetector";
    }

    @Override
    public ChangeResult detectChanges(ConfigurationChangeContext context) {
        // Detect filter definition changes
        Set<String> modifiedFilterNames = findModifiedFilterDefinitions(context);

        // Detect default filters changes (order matters for filter chain execution)
        boolean defaultFiltersChanged = hasDefaultFiltersChanged(context);

        // Find impacted clusters
        List<String> clustersToModify = findImpactedClusters(modifiedFilterNames, defaultFiltersChanged, context);

        return new ChangeResult(List.of(), List.of(), clustersToModify);
    }

    /**
     * Find filter definitions that have been modified.
     * A filter is considered modified if the type or config changed.
     * Note: Filter additions/removals are not tracked here as they're handled by Configuration validation.
     */
    private Set<String> findModifiedFilterDefinitions(ConfigurationChangeContext context) {
        Map<String, NamedFilterDefinition> oldDefs = buildFilterDefMap(context.oldConfig());
        Map<String, NamedFilterDefinition> newDefs = buildFilterDefMap(context.newConfig());

        Set<String> modifiedFilterNames = new HashSet<>();

        // Check each new definition to see if it differs from the old one
        for (Map.Entry<String, NamedFilterDefinition> entry : newDefs.entrySet()) {
            String filterName = entry.getKey();
            NamedFilterDefinition newDef = entry.getValue();
            NamedFilterDefinition oldDef = oldDefs.get(filterName);

            // Filter exists in both configs - check if it changed
            if (oldDef != null && !oldDef.equals(newDef)) {
                modifiedFilterNames.add(filterName);
            }
        }

        return modifiedFilterNames;
    }

    /**
     * Check if the default filters list has changed.
     * Order matters because filter chain execution is sequential.
     */
    private boolean hasDefaultFiltersChanged(ConfigurationChangeContext context) {
        List<String> oldDefaults = context.oldConfig().defaultFilters();
        List<String> newDefaults = context.newConfig().defaultFilters();
        // Use Objects.equals for null-safe comparison - checks both content AND order
        return !Objects.equals(oldDefaults, newDefaults);
    }

    /**
     * Find virtual clusters that are impacted by filter changes.
     * Uses a simple single-pass approach: iterate through each cluster and check if it's
     * affected by any filter change. Prioritizes code clarity over optimization.
     */
    private List<String> findImpactedClusters(
            Set<String> modifiedFilterNames,
            boolean defaultFiltersChanged,
            ConfigurationChangeContext context) {

        // Early return if nothing changed
        if (modifiedFilterNames.isEmpty() && !defaultFiltersChanged) {
            return List.of();
        }

        List<String> impactedClusters = new ArrayList<>();

        // Simple approach: check each cluster's resolved filters
        for (VirtualClusterModel cluster : context.newModels()) {
            String clusterName = cluster.getClusterName();

            // Get this cluster's resolved filters (either explicit or from defaults)
            List<String> clusterFilterNames = cluster.getFilters()
                    .stream()
                    .map(NamedFilterDefinition::name)
                    .toList();

            // Check if cluster uses any modified filter OR uses defaults and defaults changed
            boolean usesModifiedFilter = clusterFilterNames.stream()
                    .anyMatch(modifiedFilterNames::contains);

            boolean usesChangedDefaults = defaultFiltersChanged &&
                    clusterUsesDefaults(cluster, context.newConfig());

            if (usesModifiedFilter || usesChangedDefaults) {
                impactedClusters.add(clusterName);
            }
        }

        return impactedClusters;
    }

    /**
     * Check if a cluster uses default filters.
     * A cluster uses defaults if it doesn't specify its own filters list.
     */
    private boolean clusterUsesDefaults(VirtualClusterModel cluster, Configuration config) {
        VirtualCluster vc = config.virtualClusters().stream()
                .filter(v -> v.name().equals(cluster.getClusterName()))
                .findFirst()
                .orElse(null);

        // Cluster uses defaults if it doesn't specify its own filters
        return vc != null && vc.filters() == null;
    }
}
```

### 9. Supporting Records

**ConfigurationChangeContext** - Immutable context for change detection.
- **What it does**: Provides a single object containing all the data needed for change detection, including both old and new configurations and their pre-computed models
- **Key fields**: `oldConfig`, `newConfig`, `oldModels`, `newModels`, `oldFilterChainFactory`, `newFilterChainFactory`
- **Why FilterChainFactory is included**: Enables filter-related change detectors to reference the factories for comparison

```java
public record ConfigurationChangeContext(
        Configuration oldConfig,
        Configuration newConfig,
        List<VirtualClusterModel> oldModels,
        List<VirtualClusterModel> newModels,
        @Nullable FilterChainFactory oldFilterChainFactory,
        @Nullable FilterChainFactory newFilterChainFactory) {}
```

**ChangeResult** - Result of change detection.
- **What it does**: Contains categorized lists of cluster names for each operation type needed
- **Key fields**: `clustersToRemove`, `clustersToAdd`, `clustersToModify`
- **Utility methods**: `hasChanges()` to check if any changes detected, `getTotalOperations()` to get total count

```java
public record ChangeResult(
        List<String> clustersToRemove,
        List<String> clustersToAdd,
        List<String> clustersToModify) {

    public boolean hasChanges() {
        return !clustersToRemove.isEmpty() || !clustersToAdd.isEmpty() || !clustersToModify.isEmpty();
    }

    public int getTotalOperations() {
        return clustersToRemove.size() + clustersToAdd.size() + clustersToModify.size();
    }
}
```

**ReloadResponse** - HTTP response payload.
- **What it does**: Serializable record that represents the JSON response sent back to HTTP clients
- **Key fields**: `success`, `message`, `clustersModified`, `clustersAdded`, `clustersRemoved`, `timestamp`
- **Factory methods**: `from(ReloadResult)` to convert internal result, `error(message)` for error responses

```java
public record ReloadResponse(
        boolean success,
        String message,
        int clustersModified,
        int clustersAdded,
        int clustersRemoved,
        String timestamp) {

    public static ReloadResponse from(ReloadResult result) {
        return new ReloadResponse(
                result.isSuccess(),
                result.getMessage(),
                result.getClustersModified(),
                result.getClustersAdded(),
                result.getClustersRemoved(),
                result.getTimestamp().toString());
    }

    public static ReloadResponse error(String message) {
        return new ReloadResponse(false, message, 0, 0, 0, Instant.now().toString());
    }
}
```

**ReloadStateManager** - Tracks reload state and history.
- **What it does**: Maintains the current reload state and a history of recent reload operations for observability
- **Key responsibilities**: Tracks `IDLE`/`IN_PROGRESS` state, records success/failure with `ReloadResult`, maintains bounded history (max 10 entries)
- **Thread safety**: Uses `AtomicReference` for state and `synchronized` blocks for history access

```java
public class ReloadStateManager {

    private static final int MAX_HISTORY_SIZE = 10;

    private final AtomicReference<ReloadState> currentState;
    private final Deque<ReloadResult> reloadHistory;

    public enum ReloadState {
        IDLE,
        IN_PROGRESS
    }

    public void startReload() {
        currentState.set(ReloadState.IN_PROGRESS);
    }

    public void recordSuccess(ReloadResult result) {
        currentState.set(ReloadState.IDLE);
        addToHistory(result);
    }

    public void recordFailure(Throwable error) {
        currentState.set(ReloadState.IDLE);
        addToHistory(ReloadResult.failure(error.getMessage()));
    }

    public ReloadState getCurrentState() {
        return currentState.get();
    }

    public Optional<ReloadResult> getLastResult() {
        synchronized (reloadHistory) {
            return reloadHistory.isEmpty() ? Optional.empty() : Optional.of(reloadHistory.peekLast());
        }
    }
}
```

## Integration with KafkaProxy

The `KafkaProxy` class initializes the reload orchestrator and passes it to the management endpoint.

- **What it does**: `KafkaProxy` is the entry point to the proxy app and is responsible for setting up all hot-reload components
- **Key Responsibilities:**
    - Creates `ConnectionTracker` and `InFlightMessageTracker` for connection management
    - Creates `ConnectionDrainManager` and `VirtualClusterManager` for cluster lifecycle operations
    - Creates `ConfigurationChangeHandler` with list of change detectors (`VirtualClusterChangeDetector`, `FilterChangeDetector`)
    - Creates `AtomicReference<FilterChainFactory>` that is shared between `KafkaProxyInitializer` and `ConfigurationReloadOrchestrator` for atomic factory swaps
    - Creates `ConfigurationReloadOrchestrator` and passes it to `ManagementInitializer` for HTTP endpoint registration
- **Why AtomicReference is used**: Both the initializers (which create filter chains for new connections) and the orchestrator (which swaps factories on reload) need access to the current factory. Using `AtomicReference` enables atomic, thread-safe swaps.

```java
public final class KafkaProxy implements AutoCloseable {

    // Shared mutable reference to FilterChainFactory - enables atomic swaps during hot reload
    private AtomicReference<FilterChainFactory> filterChainFactoryRef;

    private final ConfigurationChangeHandler configurationChangeHandler;
    private final @Nullable ConfigurationReloadOrchestrator reloadOrchestrator;

    public KafkaProxy(PluginFactoryRegistry pfr, Configuration config, Features features, @Nullable Path configFilePath) {
        // Initialize connection management components
        this.connectionDrainManager = new ConnectionDrainManager(connectionTracker, inFlightTracker);
        this.virtualClusterManager = new VirtualClusterManager(endpointRegistry, connectionDrainManager);

        // Initialize configuration change handler with detectors
        this.configurationChangeHandler = new ConfigurationChangeHandler(
                List.of(
                        new VirtualClusterChangeDetector(),
                        new FilterChangeDetector()),
                virtualClusterManager);

        // Create AtomicReference for FilterChainFactory
        this.filterChainFactoryRef = new AtomicReference<>();

        // Initialize reload orchestrator for HTTP endpoint
        this.reloadOrchestrator = new ConfigurationReloadOrchestrator(
                config,
                configurationChangeHandler,
                pfr,
                features,
                configFilePath,
                filterChainFactoryRef);
    }

    public CompletableFuture<Void> startup() {
        // Create initial FilterChainFactory and store in shared atomic reference
        FilterChainFactory initialFactory = new FilterChainFactory(pfr, config.filterDefinitions());
        this.filterChainFactoryRef.set(initialFactory);

        // Pass atomic reference to initializers for dynamic factory swaps
        var tlsServerBootstrap = buildServerBootstrap(proxyEventGroup,
                new KafkaProxyInitializer(filterChainFactoryRef, ...));
        var plainServerBootstrap = buildServerBootstrap(proxyEventGroup,
                new KafkaProxyInitializer(filterChainFactoryRef, ...));

        // Start management listener with reload orchestrator
        var managementFuture = maybeStartManagementListener(managementEventGroup, meterRegistries, reloadOrchestrator);

        // ...
    }
}
```

## Flow Diagram

```
┌───────────────────────────────────────────────────────────────────────────┐
│                         HTTP POST /admin/config/reload                     │
│                         Content-Type: application/yaml                     │
│                         Body: <new YAML configuration>                     │
└───────────────────────────────────┬───────────────────────────────────────┘
                                    │
                                    ▼
┌───────────────────────────────────────────────────────────────────────────┐
│                     ConfigurationReloadEndpoint                            │
│                     - Creates ReloadRequestContext                         │
│                     - Delegates to ReloadRequestProcessor                  │
└───────────────────────────────────┬───────────────────────────────────────┘
                                    │
                                    ▼
┌───────────────────────────────────────────────────────────────────────────┐
│                     ReloadRequestProcessor                                 │
│                     - Chain of Responsibility pattern                      │
│                                                                            │
│   ┌─────────────────┐   ┌──────────────────┐   ┌────────────────────────┐ │
│   │ ContentType     │ → │ ContentLength    │ → │ ConfigurationParsing   │ │
│   │ Validation      │   │ Validation       │   │ Handler                │ │
│   └─────────────────┘   └──────────────────┘   └────────────┬───────────┘ │
│                                                              │             │
│                                                              ▼             │
│                                           ┌────────────────────────────┐  │
│                                           │ ConfigurationReload        │  │
│                                           │ Handler                    │  │
│                                           └────────────┬───────────────┘  │
└────────────────────────────────────────────────────────┼──────────────────┘
                                                         │
                                                         ▼
┌───────────────────────────────────────────────────────────────────────────┐
│                 ConfigurationReloadOrchestrator                            │
│                 - Concurrency control (ReentrantLock)                      │
│                 - Configuration validation                                 │
│                 - Creates new FilterChainFactory                           │
│                 - Builds ConfigurationChangeContext                        │
└───────────────────────────────────┬───────────────────────────────────────┘
                                    │
                                    ▼
┌───────────────────────────────────────────────────────────────────────────┐
│                 ConfigurationChangeHandler                                 │
│                 - Coordinates change detectors                             │
│                 - Aggregates change results                                │
│                                                                            │
│   ┌──────────────────────────┐    ┌────────────────────────┐              │
│   │ VirtualClusterChange     │    │ FilterChangeDetector   │              │
│   │ Detector                 │    │                        │              │
│   │ - New clusters           │    │ - Modified filters     │              │
│   │ - Removed clusters       │    │ - Default filters      │              │
│   │ - Modified clusters      │    │ - Impacted clusters    │              │
│   └──────────────┬───────────┘    └───────────┬────────────┘              │
│                  │                            │                           │
│                  └─────────────┬──────────────┘                           │
│                                │                                          │
│                                ▼                                          │
│                     ┌──────────────────────┐                              │
│                     │     ChangeResult     │                              │
│                     │ - clustersToRemove   │                              │
│                     │ - clustersToAdd      │                              │
│                     │ - clustersToModify   │                              │
│                     └──────────┬───────────┘                              │
└────────────────────────────────┼──────────────────────────────────────────┘
                                 │
                                 ▼
                    ┌────────────────────────┐
                    │ VirtualClusterManager  │ ────► Part 2: Graceful Restart
                    │ - Remove clusters      │
                    │ - Add clusters         │
                    │ - Restart clusters     │
                    └────────────────────────┘
                                 │
                                 ▼
┌───────────────────────────────────────────────────────────────────────────┐
│                          ON SUCCESS                                        │
│                                                                            │
│   ┌─────────────────────────────────────────────────────────────────────┐ │
│   │ filterChainFactoryRef.set(newFactory)  ◄── Atomic swap!             │ │
│   │ oldFactory.close()                                                   │ │
│   │ currentConfiguration = newConfig                                     │ │
│   │ persistConfigurationToDisk(newConfig)                                │ │
│   └─────────────────────────────────────────────────────────────────────┘ │
└───────────────────────────────────┬───────────────────────────────────────┘
                                    │
                                    ▼
┌───────────────────────────────────────────────────────────────────────────┐
│                          HTTP 200 OK                                       │
│                          Content-Type: application/json                    │
│                          {"success": true, "clustersModified": 1, ...}     │
└───────────────────────────────────────────────────────────────────────────┘
```

---

# Part 2: Graceful Virtual Cluster Restart

Part 2 of the hot-reload implementation focuses on gracefully restarting virtual clusters. This component receives structured change operations from Part 1 and executes them in a carefully orchestrated sequence: **connection draining → resource deregistration → new resource registration → connection restoration.**

The design emphasizes minimal service disruption by ensuring all in-flight Kafka requests complete before closing connections (or when a timeout is hit).

## Core Classes & Structure

### 1. VirtualClusterManager

Acts as the high-level orchestrator for all virtual cluster lifecycle operations during hot-reload. `ConfigurationChangeHandler` calls the `VirtualClusterManager` to restart/add/remove clusters when there is a config change.

- **What it does**: Manages the complete lifecycle of virtual clusters including addition, removal, and restart operations
- **Key Responsibilities:**
    - **Cluster Addition**: Takes a new `VirtualClusterModel` and brings it online by registering all gateways with `EndpointRegistry`
    - **Cluster Removal**: Safely takes down an existing cluster by first draining all connections gracefully via `ConnectionDrainManager`, then deregistering from `EndpointRegistry`
    - **Cluster Restart**: Performs a complete cluster reconfiguration by orchestrating remove → add sequence with updated settings
    - **Rollback Integration**: Automatically tracks all successful operations via `ConfigurationChangeRollbackTracker` so they can be undone if later operations fail

```java
public class VirtualClusterManager {

    private final EndpointRegistry endpointRegistry;
    private final ConnectionDrainManager connectionDrainManager;

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
        VirtualClusterModel clusterToRemove = findClusterModel(oldModels, clusterName);

        // 1. Drain connections gracefully (30s timeout)
        return connectionDrainManager.gracefullyDrainConnections(clusterName, Duration.ofSeconds(30))
                .thenCompose(v -> {
                    // 2. Deregister all gateways from endpoint registry
                    var deregistrationFutures = clusterToRemove.gateways().values().stream()
                            .map(gateway -> endpointRegistry.deregisterVirtualCluster(gateway))
                            .toArray(CompletableFuture[]::new);

                    return CompletableFuture.allOf(deregistrationFutures);
                })
                .thenRun(() -> {
                    // 3. Track removal for potential rollback
                    rollbackTracker.trackRemoval(clusterName, clusterToRemove);
                    LOGGER.info("Successfully removed virtual cluster '{}'", clusterName);
                });
    }

    /**
     * Restarts a virtual cluster with new configuration (remove + add).
     */
    public CompletableFuture<Void> restartVirtualCluster(String clusterName, 
                                                         VirtualClusterModel newModel,
                                                         List<VirtualClusterModel> oldModels,
                                                         ConfigurationChangeRollbackTracker rollbackTracker) {
        VirtualClusterModel oldModel = findClusterModel(oldModels, clusterName);

        // Step 1: Remove existing cluster (drain + deregister)
        return removeVirtualCluster(clusterName, oldModels, rollbackTracker)
                .thenCompose(v -> {
                    // Step 2: Add new cluster with updated configuration
                    return addVirtualCluster(newModel, rollbackTracker);
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
    public CompletableFuture<Void> addVirtualCluster(VirtualClusterModel newModel,
                                                     ConfigurationChangeRollbackTracker rollbackTracker) {
        String clusterName = newModel.getClusterName();

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
        var registrationFutures = model.gateways().values().stream()
                .map(gateway -> endpointRegistry.registerVirtualCluster(gateway))
                .toArray(CompletableFuture[]::new);

        return CompletableFuture.allOf(registrationFutures);
    }
}
```

### 2. ConnectionDrainManager

Implements the graceful connection draining strategy during cluster restarts. This is what makes hot-reload "graceful" - it ensures that client requests in progress are completed rather than dropped.

- **What it does**: Manages the graceful shutdown of connections during cluster restart, ensuring no in-flight messages are lost
- **Key Responsibilities:**
    - **Draining Mode Control**: Maintains a map of draining clusters; when a cluster enters drain mode, `shouldAcceptConnection()` returns false to reject new connections
    - **Backpressure Strategy**: Sets `autoRead = false` only on downstream (client→proxy) channels to prevent new requests, while keeping upstream (proxy→Kafka) channels reading to allow responses to complete naturally
    - **In-Flight Monitoring**: Uses a scheduled executor to periodically check `InFlightMessageTracker` (every 100ms) and closes channels when pending requests reach zero
    - **Timeout Handling**: If in-flight count doesn't reach zero within the timeout (default 30s), force-closes the channel to prevent indefinite hangs
    - **Resource Cleanup**: Implements `AutoCloseable` to properly shut down the scheduler on proxy shutdown
- **Explanation of the Draining Strategy:**
    - **Phase 1**: Enter draining mode → new connection attempts are rejected
    - **Phase 2**: Apply backpressure → downstream `autoRead=false`, upstream `autoRead=true`
    - **Phase 3**: Monitor in-flight messages → wait for count to reach zero or timeout, then close channel

```java
public class ConnectionDrainManager implements AutoCloseable {

    private final ConnectionTracker connectionTracker;
    private final InFlightMessageTracker inFlightTracker;
    private final Map<String, AtomicBoolean> drainingClusters = new ConcurrentHashMap<>();
    private final ScheduledExecutorService scheduler;

    public ConnectionDrainManager(ConnectionTracker connectionTracker,
                                  InFlightMessageTracker inFlightTracker) {
        this.connectionTracker = connectionTracker;
        this.inFlightTracker = inFlightTracker;
        this.scheduler = new ScheduledThreadPoolExecutor(2, r -> {
            Thread t = new Thread(r, "connection-drain-manager");
            t.setDaemon(true);
            return t;
        });
    }

    /**
     * Determines if a new connection should be accepted for the specified virtual cluster.
     */
    public boolean shouldAcceptConnection(String clusterName) {
        return !isDraining(clusterName);
    }

    /**
     * Performs a complete graceful drain operation by stopping new connections
     * and immediately closing existing connections after in-flight messages complete.
     */
    public CompletableFuture<Void> gracefullyDrainConnections(String clusterName, Duration totalTimeout) {
        int totalActiveConnections = connectionTracker.getTotalConnectionCount(clusterName);
        int totalInFlightRequests = inFlightTracker.getTotalPendingRequestCount(clusterName);

        LOGGER.info("Starting graceful drain for cluster '{}' with {} connections and {} in-flight requests",
                clusterName, totalActiveConnections, totalInFlightRequests);

        return startDraining(clusterName)
                .thenCompose(v -> {
                    if (totalActiveConnections == 0) {
                        return CompletableFuture.completedFuture(null);
                    }
                    else {
                        return gracefullyCloseConnections(clusterName, totalTimeout);
                    }
                });
    }

    /**
     * Starts draining - new connections will be rejected.
     */
    public CompletableFuture<Void> startDraining(String clusterName) {
        drainingClusters.put(clusterName, new AtomicBoolean(true));
        return CompletableFuture.completedFuture(null);
    }

    /**
     * Gracefully closes all active connections for the specified virtual cluster.
     * Strategy: Disable autoRead on downstream channels to prevent new requests,
     * but keep upstream channels reading to allow responses to complete naturally.
     */
    public CompletableFuture<Void> gracefullyCloseConnections(String clusterName, Duration timeout) {
        Set<Channel> downstreamChannels = connectionTracker.getDownstreamActiveChannels(clusterName);
        Set<Channel> upstreamChannels = connectionTracker.getUpstreamActiveChannels(clusterName);

        var allCloseFutures = new ArrayList<CompletableFuture<Void>>();

        // STRATEGY:
        // - Downstream (autoRead=false): Prevents new client requests from being processed
        // - Upstream (autoRead=true): Allows Kafka responses to be processed normally

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
                KafkaProxyFrontendHandler frontendHandler = 
                    downstreamChannel.pipeline().get(KafkaProxyFrontendHandler.class);
                if (frontendHandler != null) {
                    frontendHandler.applyBackpressure();
                }
                else {
                    downstreamChannel.config().setAutoRead(false);
                }
            }
        }
        catch (Exception e) {
            LOGGER.warn("Failed to disable autoRead for downstream channel - continuing", e);
        }
        return downstreamChannel;
    }

    /**
     * Gracefully closes a single channel.
     * Monitors in-flight count every 100ms, closes when zero or on timeout.
     */
    private CompletableFuture<Void> gracefullyCloseChannel(Channel channel, String clusterName, 
                                                           Duration timeout, String channelType) {
        CompletableFuture<Void> future = new CompletableFuture<>();
        long timeoutMillis = timeout.toMillis();
        long startTime = System.currentTimeMillis();

        // Schedule timeout
        ScheduledFuture<?> timeoutTask = scheduler.schedule(() -> {
            if (!future.isDone()) {
                LOGGER.warn("Graceful shutdown timeout - forcing closure");
                closeChannelImmediately(channel, future);
            }
        }, timeoutMillis, TimeUnit.MILLISECONDS);

        // Schedule periodic checks for in-flight messages
        ScheduledFuture<?> checkTask = scheduler.scheduleAtFixedRate(() -> {
            if (future.isDone()) return;

            int pendingRequests = inFlightTracker.getPendingRequestCount(clusterName, channel);
            if (pendingRequests == 0) {
                closeChannelImmediately(channel, future);
            }
        }, 50, 100, TimeUnit.MILLISECONDS);

        // Cancel tasks when done
        future.whenComplete((result, throwable) -> {
            timeoutTask.cancel(false);
            checkTask.cancel(false);
        });

        return future;
    }

    private void closeChannelImmediately(Channel channel, CompletableFuture<Void> future) {
        if (future.isDone()) return;

        channel.close().addListener(channelFuture -> {
            if (channelFuture.isSuccess()) {
                future.complete(null);
            }
            else {
                future.completeExceptionally(channelFuture.cause());
            }
        });
    }
}
```

### 3. ConnectionTracker

Maintains real-time inventory of all active network connections per virtual cluster.

- **What it does**: Provides real-time visibility into all active connections (downstream and upstream) for each virtual cluster
- **Key Responsibilities:**
    - **Bidirectional Tracking**: Separately tracks downstream connections (client→proxy) and upstream connections (proxy→Kafka) using `ConcurrentHashMap`
    - **Channel Management**: Maintains collections of active `Channel` objects for bulk operations like graceful closure
    - **Lifecycle Integration**: Integrates with `ProxyChannelStateMachine` to automatically track connection establishment and closure events
    - **Cleanup Logic**: Automatically removes references to closed channels and cleans up empty cluster entries to prevent memory leaks
    - **Thread Safety**: Uses `ConcurrentHashMap` and `AtomicInteger` for thread-safe operations from multiple Netty event loops

```java
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

    public Set<Channel> getDownstreamActiveChannels(String clusterName) {
        Set<Channel> channels = downstreamChannelsByCluster.get(clusterName);
        return channels != null ? Set.copyOf(channels) : Set.of();
    }

    // Similar methods for upstream connections...

    public int getTotalConnectionCount(String clusterName) {
        return getDownstreamActiveConnectionCount(clusterName) + getUpstreamActiveConnectionCount(clusterName);
    }

    private void onConnectionClosed(String clusterName, Channel channel,
                                    Map<String, AtomicInteger> connectionCounters,
                                    Map<String, Set<Channel>> channelsByCluster) {
        AtomicInteger counter = connectionCounters.get(clusterName);
        if (counter != null) {
            counter.decrementAndGet();
            if (counter.get() <= 0) {
                connectionCounters.remove(clusterName);
            }
        }

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

### 4. InFlightMessageTracker

Tracks pending Kafka requests to ensure no messages are lost during connection closure.

- **What it does**: Maintains counters of pending Kafka requests per channel and cluster to enable "wait for completion" strategy during graceful shutdown
- **Key Responsibilities:**
    - **Request Tracking**: Increments counters when Kafka requests are sent upstream (called from `ProxyChannelStateMachine.messageFromClient()`)
    - **Response Tracking**: Decrements counters when Kafka responses are received (called from `ProxyChannelStateMachine.messageFromServer()`)
    - **Per-Channel Counts**: Maintains a two-level map: `cluster name → channel → pending count` for granular tracking
    - **Cluster Totals**: Maintains a separate map for quick cluster-wide total lookup without iterating all channels
    - **Channel Cleanup**: When a channel closes unexpectedly, adjusts counts appropriately to prevent stuck counters
    - **Thread Safety**: Uses `ConcurrentHashMap` and `AtomicInteger` for thread-safe concurrent access

```java
public class InFlightMessageTracker {

    // Map from cluster name to channel to pending request count
    private final Map<String, Map<Channel, AtomicInteger>> pendingRequests = new ConcurrentHashMap<>();

    // Map from cluster name to total pending requests for quick lookup
    private final Map<String, AtomicInteger> totalPendingByCluster = new ConcurrentHashMap<>();

    /**
     * Records that a request has been sent to the upstream cluster.
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
     * Records that a channel has been closed, clearing all pending requests.
     */
    public void onChannelClosed(String clusterName, Channel channel) {
        Map<Channel, AtomicInteger> clusterRequests = pendingRequests.get(clusterName);
        if (clusterRequests != null) {
            AtomicInteger channelCounter = clusterRequests.remove(channel);
            if (channelCounter != null) {
                int pendingCount = channelCounter.get();
                if (pendingCount > 0) {
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

    public int getPendingRequestCount(String clusterName, Channel channel) {
        Map<Channel, AtomicInteger> clusterRequests = pendingRequests.get(clusterName);
        if (clusterRequests != null) {
            AtomicInteger counter = clusterRequests.get(channel);
            return counter != null ? Math.max(0, counter.get()) : 0;
        }
        return 0;
    }

    public int getTotalPendingRequestCount(String clusterName) {
        AtomicInteger counter = totalPendingByCluster.get(clusterName);
        return counter != null ? Math.max(0, counter.get()) : 0;
    }
}
```

### 5. ConfigurationChangeRollbackTracker

Maintains a record of all cluster operations so they can be reversed if the overall configuration change fails.

- **What it does**: Records all successful cluster operations during a configuration change so they can be undone if a later operation fails
- **Key Responsibilities:**
    - **Removal Tracking**: Stores the cluster name and original `VirtualClusterModel` for each removed cluster, enabling re-addition on rollback
    - **Modification Tracking**: Stores both the original and new `VirtualClusterModel` for each modified cluster, enabling revert to original state
    - **Addition Tracking**: Stores the cluster name and `VirtualClusterModel` for each added cluster, enabling removal on rollback
    - **Rollback Order**: Provides ordered lists to enable rollback in reverse order: Added → Modified → Removed

```java
public class ConfigurationChangeRollbackTracker {

    private final List<String> removedClusters = new ArrayList<>();
    private final List<String> modifiedClusters = new ArrayList<>();
    private final List<String> addedClusters = new ArrayList<>();

    private final Map<String, VirtualClusterModel> removedModels = new HashMap<>();
    private final Map<String, VirtualClusterModel> originalModels = new HashMap<>();
    private final Map<String, VirtualClusterModel> modifiedModels = new HashMap<>();
    private final Map<String, VirtualClusterModel> addedModels = new HashMap<>();

    public void trackRemoval(String clusterName, VirtualClusterModel removedModel) {
        removedClusters.add(clusterName);
        removedModels.put(clusterName, removedModel);
    }

    public void trackModification(String clusterName, VirtualClusterModel originalModel, 
                                  VirtualClusterModel newModel) {
        modifiedClusters.add(clusterName);
        originalModels.put(clusterName, originalModel);
        modifiedModels.put(clusterName, newModel);
    }

    public void trackAddition(String clusterName, VirtualClusterModel addedModel) {
        addedClusters.add(clusterName);
        addedModels.put(clusterName, addedModel);
    }

    // Getter methods for rollback operations...
}
```

### 6. Integration with ProxyChannelStateMachine

The existing `ProxyChannelStateMachine` is enhanced to integrate with connection tracking and in-flight message tracking.

- **What it does**: Adds hooks into the existing state machine to notify `ConnectionTracker` and `InFlightMessageTracker` of connection and message lifecycle events
- **Key Responsibilities:**
    - **Connection Lifecycle**: Automatically notifies `ConnectionTracker` when connections are established (`toClientActive`, `toForwarding`) and closed (`onServerInactive`, `onClientInactive`)
    - **In-flight Message Tracking**: Automatically notifies `InFlightMessageTracker` when requests are sent upstream (`messageFromClient`) and responses received (`messageFromServer`)
    - **Cleanup on Close**: Ensures `InFlightMessageTracker.onChannelClosed()` is called when channels close to clear any pending counts

```java
// Example integration points in ProxyChannelStateMachine

void messageFromServer(Object msg) {
    // Track responses received from upstream Kafka
    if (inFlightTracker != null && msg instanceof ResponseFrame && backendHandler != null) {
        inFlightTracker.onResponseReceived(clusterName, backendHandler.serverCtx().channel());
    }
    // ... existing logic
}

void messageFromClient(Object msg) {
    // Track requests being sent upstream
    if (inFlightTracker != null && msg instanceof RequestFrame && backendHandler != null) {
        inFlightTracker.onRequestSent(clusterName, backendHandler.serverCtx().channel());
    }
    // ... existing logic
}

void onServerInactive() {
    // Track upstream connection closure
    if (connectionTracker != null && backendHandler != null) {
        connectionTracker.onUpstreamConnectionClosed(clusterName, backendHandler.serverCtx().channel());
    }
    // Clear any pending in-flight messages
    if (inFlightTracker != null && backendHandler != null) {
        inFlightTracker.onChannelClosed(clusterName, backendHandler.serverCtx().channel());
    }
    // ... existing logic
}

void onClientInactive() {
    // Track downstream connection closure
    if (connectionTracker != null && frontendHandler != null) {
        connectionTracker.onDownstreamConnectionClosed(clusterName, frontendHandler.clientCtx().channel());
    }
    if (inFlightTracker != null && frontendHandler != null) {
        inFlightTracker.onChannelClosed(clusterName, frontendHandler.clientCtx().channel());
    }
    // ... existing logic
}

private void toClientActive(ProxyChannelState.ClientActive clientActive,
                            KafkaProxyFrontendHandler frontendHandler) {
    // Track downstream connection establishment
    if (connectionTracker != null) {
        connectionTracker.onDownstreamConnectionEstablished(clusterName, frontendHandler.clientCtx().channel());
    }
    // ... existing logic
}

private void toForwarding(Forwarding forwarding) {
    // Track upstream connection establishment
    if (connectionTracker != null && backendHandler != null) {
        connectionTracker.onUpstreamConnectionEstablished(clusterName, backendHandler.serverCtx().channel());
    }
    // ... existing logic
}
```

### 7. Rejecting New Connections During Drain

The `KafkaProxyFrontendHandler` checks if a cluster is draining before accepting new connections.

- **What it does**: Adds a guard check in `channelActive()` to reject new connections when a cluster is being drained
- **How it works**: Calls `connectionDrainManager.shouldAcceptConnection(clusterName)` before allowing the connection to proceed. If the cluster is draining, immediately closes the channel with a log message.
- **Why this is needed**: Without this check, new connections could be established while we're trying to drain existing connections, making the drain process take longer or never complete.

```java
public class KafkaProxyFrontendHandler
        extends ChannelInboundHandlerAdapter
        implements NetFilter.NetFilterContext {

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
}
```

## Graceful Restart Flow Diagram

```
┌───────────────────────────────────────────────────────────────────────────┐
│                       PHASE 1: INITIATE DRAINING                          │
│                                                                           │
│   VirtualClusterManager.restartVirtualCluster()                           │
│                     │                                                     │
│                     ▼                                                     │
│   ConnectionDrainManager.startDraining(clusterName)                       │
│   - drainingClusters.put(clusterName, true)                               │
│   - New connections will be REJECTED                                      │
└───────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌───────────────────────────────────────────────────────────────────────────┐
│                    PHASE 2: APPLY BACKPRESSURE                            │
│                                                                           │
│   ConnectionDrainManager.gracefullyCloseConnections()                     │
│                                                                           │
│   For each DOWNSTREAM channel (client → proxy):                           │
│   - channel.config().setAutoRead(false)                                   │
│   - Stops receiving NEW client requests                                   │
│                                                                           │
│   For each UPSTREAM channel (proxy → Kafka):                              │
│   - autoRead remains TRUE                                                 │
│   - Continues receiving Kafka responses                                   │
│                                                                           │
│   Result: In-flight count decreases naturally as responses arrive         │
└───────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌───────────────────────────────────────────────────────────────────────────┐
│                  PHASE 3: MONITOR & CLOSE CHANNELS                        │
│                                                                           │
│   For each channel:                                                       │
│   ┌─────────────────────────────────────────────────────────────────────┐ │
│   │  scheduler.scheduleAtFixedRate(() -> {                              │ │
│   │      pendingRequests = inFlightTracker.getPendingRequestCount()     │ │
│   │                                                                     │ │
│   │      if (pendingRequests == 0) {                                    │ │
│   │          channel.close()  ◄── Safe to close!                        │ │
│   │      }                                                              │ │
│   │  }, 50ms, 100ms)                                                    │ │
│   │                                                                     │ │
│   │  scheduler.schedule(() -> {                                         │ │
│   │      if (!done) channel.close()  ◄── Force close on timeout         │ │
│   │  }, 30 seconds)                                                     │ │
│   └─────────────────────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌───────────────────────────────────────────────────────────────────────────┐
│                    PHASE 4: DEREGISTER & REGISTER                         │
│                                                                           │
│   endpointRegistry.deregisterVirtualCluster(oldGateway)                   │
│   - Unbinds network ports                                                 │
│                                                                           │
│   endpointRegistry.registerVirtualCluster(newGateway)                     │
│   - Binds network ports with new configuration                            │
└───────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌───────────────────────────────────────────────────────────────────────────┐
│                       PHASE 5: STOP DRAINING                              │
│                                                                           │
│   ConnectionDrainManager.stopDraining(clusterName)                        │
│   - drainingClusters.remove(clusterName)                                  │
│   - New connections now ACCEPTED                                          │
│   - Cluster is fully operational with new configuration                   │
└───────────────────────────────────────────────────────────────────────────┘
```

---

# Example Usage

## Triggering a Reload with curl

```bash
curl -X POST http://localhost:9190/admin/config/reload \
  -H "Content-Type: application/yaml" \
  --data-binary @new-config.yaml
```

**Response:**
```json
{
  "success": true,
  "message": "Configuration reloaded successfully",
  "clustersModified": 1,
  "clustersAdded": 1,
  "clustersRemoved": 0,
  "timestamp": "2024-01-15T10:30:00.123456Z"
}
```

## Example Configuration with Reload Endpoint

```yaml
management:
  bindAddress: 0.0.0.0
  port: 9190
  endpoints:
    prometheus: {}
    configReload:
      enabled: true
      timeout: 60s

virtualClusters:
- name: "demo-cluster"
  targetCluster:
    bootstrapServers: "broker:9092"
  gateways:
  - name: "default-gateway"
    portIdentifiesNode:
      bootstrapAddress: "localhost:9092"
```

---
