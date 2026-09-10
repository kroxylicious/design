# 133 - Allow over-long authentication sessions in `SaslTermination`

Allow over-long authentication sessions in the `SaslTermination` filter added by [Proposal 124](124-sasl-termination.md).

## Current situation

Proposal 124 added the `SaslTermination` filter with support for OAUTHBEARER, SCRAM-SHA-256 and SCRAM-SHA-512.
The filter supports [KIP-368 reauthentication](https://cwiki.apache.org/confluence/spaces/KAFKA/pages/89068981/KIP-368+Allow+SASL+Connections+to+Periodically+Re-Authenticate), and for OAUTHBEARER access tokens the reauthentication time advertized to the client is based on the access token's own expiry (`expires_in`).

## Motivation

A contributor has [commented](https://github.com/kroxylicious/kroxylicious/issues/4391#issuecomment-5413561636) asking about configurability of the session lifetime we advertise to clients in the `SaslAuthenticate` response and which drives subsequent reauthentication:

> Ideally JWT tokens will be short lived, [but] in a streaming scenario, it may not be ideal to re-establish the connection every 10 minutes or so. It might be sufficient to authenticate the JWT only when the connection request is made.

This cannot always be achieved by configuring a longer token lifetime on the Oauth authorization server. In general there is no upper bound on connection lifetime. 

The filter already supports a `maxTimeBeforeReauth` configuration parameter, but it cannot be used to extend a session lifetime, as described in the documentation: "the effective session expiry is the earlier of this value and the token’s own expiry."
    
## Proposal

To enable client authentication sessions that are longer-lived than token expiry we would add a new configuration:

| Name                                    | Type    | Default   |
|-----------------------------------------|---------|-----------|
| `maxTimeBeforeReauthIgnoresTokenExpiry` | boolean | `false`   |

When this is `true` the reauthentication time advertized to the Kafka client will be `maxTimeBeforeReauth`, rather than the earlier of `maxTimeBeforeReauth` and the token's own expiry. 
Setting `maxTimeBeforeReauth` to an implausibly long time, e.g. `3650d`, would be reflected in the `session_lifetime_ms` value sent back to the clients in `SaslAuthenticate` so that each Kafka session would last for the duration of the connection. 

Because configuring `maxTimeBeforeReauthIgnoresTokenExpiry: true` relaxes a more secure default we will log the following message at `WARN`:
``Ignoring OAUTHBEARER tokens' own expiry time. All SASL sessions can last as long as ${maxTimeBeforeReauth} regardless of how long the authorization server intended. Set `maxTimeBeforeReauthIgnoresTokenExpiry: false` to limit session lifetime to the minimum of ${maxTimeBeforeReauth} and the token's own expiry.``.

## Affected/not affected projects

This affects only the `SaslTermination` filter in the `kroxylicious` project.

## Compatibility

This change is backwards compatible.

## Rejected alternatives


