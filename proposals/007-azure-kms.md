# 007 - Azure KMS Implementation

One of the flagship Kroxylicious Filters is Record Encryption, enabling users to implement encryption-at-rest for their Apache Kafka cluster. To do this securely, we rely on third-party Key Management Systems (KMS) to protect a set of Key Encryption Keys which are used to encrypt the Data Encryption Keys we write into the records. We currently have AWS, Hashicorp Vault and Fortanix DSM implementations.

We should implement an Azure Key Vault integration, so that users can use Azure as their KMS for record encryption.

<!-- TOC -->
* [007 - Azure KMS Implementation](#007---azure-kms-implementation)
  * [Background](#background)
    * [Key Vault Types](#key-vault-types)
    * [Key Types & Wrapping Algorithms](#key-types--wrapping-algorithms)
    * [Authentication With Key Vault](#authentication-with-key-vault)
    * [National Clouds](#national-clouds)
    * [TLS](#tls)
    * [DEK Generation](#dek-generation)
    * [Key Identifiers](#key-identifiers)
  * [Proposed Initial Implementation](#proposed-initial-implementation)
    * [Configuration](#configuration)
<!-- TOC -->

## Background

> Azure Key Vault is a cloud service for securely storing and accessing secrets. A secret is anything that you want to tightly control access to, such as API keys, passwords, certificates, or cryptographic keys.

### Key Vault Types

There are several classes of Key Vault

- `Key Vault` - software encryption. For our purposes only supports one key type recommended for wrapping, that is RSA. This is a cheap option, charging per key rotation and operation.
- `Key Vault (premium SKU)` - software/hardware encryption. As above only supports RSA, but can use hardware (HSM-RSA) for it. More expensive.
- `Managed HSM` - hardware encryption. This supports RSA, but also quantum-resistant 256bit symmetric AES keys/algorithms. This is an expensive option, charging per hour and per key. Also has several flavours, but the key capabilities are the same.

See also:
- [About Keys](https://learn.microsoft.com/en-us/azure/key-vault/keys/about-keys)
- [How to choose the right Azure key management solution](https://learn.microsoft.com/en-us/azure/security/fundamentals/key-management-choose)

### Key Types & Wrapping Algorithms

Microsoft recommends has two recommended Key Types for a Key-wrapping workload.

1. 2048, 3072, 4096 bit RSA (or HSM-RSA) Keys using `RSA-OAEP-256`. This is a asymmetric key, differing from our existing implementations that rely on the KMS to use an AES-256-GCM key. The difference is that the wrapping operation is done with the public key, and can be done inside or outside of the KMS, but it requires the private key to decrypt. These RSA algorithms are **not** advertised as quantum-resistant. This is the only recommended wrapping type/algorithm available on a cheap software-based Key Vault instance.
2. 256-bit AES keys using `AES-GCM`, `AES-KW` or `AES-CBC`. These are advertised as quantum-resistant. 256 AES-GCM is what we use in the other KMS implementations, so there is some consistency there. It is only available in the expensive Managed HSM mode.

See [docs](https://learn.microsoft.com/en-us/azure/key-vault/keys/about-keys-details)

### Authentication With Key Vault

> Authentication with Key Vault works in conjunction with [Microsoft Entra ID](https://learn.microsoft.com/en-us/azure/active-directory/fundamentals/active-directory-whatis), which is responsible for authenticating the identity of any given security principal.

The Proxy must obtain a token that it can use to communicate with Key Vault. The options are:
1. [Microsoft identity platform and the OAuth 2.0 client credentials flow](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-client-creds-grant-flow). This is a mechanism where the application will have a Service Principal created for it in Entra, with permissions assigned to allow get/wrap/unwrap keys in a Key Vault. Then our application will make an HTTP request to Entra passing credentials and a scope, and receive a Bearer token it can attach to Key Vault requests. This flow will work for applications in any environment, they do not need to run on Azure.
2. Via [Managed Identity](https://learn.microsoft.com/en-us/azure/active-directory/managed-identities-azure-resources/overview). This is a convenient approach for applications running on Azure to obtain a token from a local non-routable IP. But as said, it's Azure only, which doesn't help if you only have a Key Vault in Azure but your workload elsewhere.

See [Authentication in Azure Key Vault](https://learn.microsoft.com/en-us/azure/key-vault/general/authentication)

One component that goes into the oauth request is the tenant id. This is a public piece of information that can be obtained
from Key Vault by making an HTTP request to it with no `Authorization` header.

The Azure SDK does this to avoid the user having to supply the tenant id. However this is a more fiddly workflow, I
think we should make the user supply the tenant id by configuration so we do not have to obtain it by a request
to Key Vault.

### National Clouds

> National clouds are physically isolated instances of Azure. These regions of Azure are designed to make sure that data residency, sovereignty, and compliance requirements are honored within geographical boundaries.

Public addresses like the Key Vault base url will be different per national cloud. For example in China an address might look like `https://vault-name.vault.azure.cn`. This also impacts the `scope` we request via the oauth client credentials flow, we would likely want to request `https://vault.azure.cn/.default` scope.

Entra oauth endpoint will vary by National Cloud

```
Global   https://login.microsoftonline.com
Microsoft Entra ID for US Government	https://login.microsoftonline.us
Microsoft Entra China operated by 21Vianet	https://login.partner.microsoftonline.cn
...
```

The implication for us is that the oauth endpoint and scope should be configurable. The vault base uri is a natural part of the configuration anyway. We could potentially infer the `scope` from the configured vault base uri.

[National clouds](https://learn.microsoft.com/en-us/entra/identity-platform/authentication-national-cloud)

### TLS

With two remote systems involved we want independently customizable TLS for:

1. the authentication client
2. the key vault client

So that we can supply custom trust or use insecure testing modes (mock servers using self-signed certs for example).

### DEK Generation

Another difference is that basic Key Vault cannot generate the DEK bytes for us. Managed HSM does have an operation to generate random bytes for us https://learn.microsoft.com/en-us/rest/api/keyvault/?view=rest-keyvault-keys-7.4#key-operations-managed-hsm-only

### Key Identifiers

When we wrap/unwrap we have to identify a key by its name and version. You can obtain the latest version by https://learn.microsoft.com/en-us/rest/api/keyvault/keys/get-key/get-key?view=rest-keyvault-keys-7.4&tabs=HTTP.

The API usually returns it as a `kid` https://learn.microsoft.com/en-us/azure/key-vault/general/about-keys-secrets-certificates#object-identifiers. Like

> For Vaults: https://{vault-name}.vault.azure.net/{object-type}/{object-name}/{object-version}

eg. `https://my-vault.vault.azure.net/keys/my-key/78deebed173b48e48f55abf87ed4cf71`

The Azure SDK then takes advantage of the fact this happens to be the base URL for various operations like wrap/unwrap.

ed. for [wrap key](https://learn.microsoft.com/en-us/rest/api/keyvault/keys/wrap-key/wrap-key?view=rest-keyvault-keys-7.4&tabs=HTTP) the url is `POST {vaultBaseUrl}/keys/{key-name}/{key-version}/wrapkey?api-version=7.4
`

To minimise EDEK bytes there are a couple of opportunities when encoding the EDEK:
1. we can exclude the vaultBaseUrl and have the limitation that we work only with a single key vault
2. we can encode just the keyName and keyVersion, and use that to decrypt
3. all documented examples of the keyVersion (and from my experimentation too) are 128bits encoded as a hexadecimal string.

So for the EDEK I think we could optimistically try to encode it as `versionByte,keyNameLength,keyName,keyVersionLength,128-bit-decoded,edek`
and fall back to using the string like `versionByte,keyNameLength,keyName,keyVersionLength,keyVersionString,edek`. So
we would have either a 16-byte version implying it's the bytes, or a 32 character string.

## Proposed Initial Implementation

1. Support all flavours of Key Vault. The APIs will be the same, just with a different vault base URI.
2. Support RSA and HSM-RSA key types, wrapping using `RSA-OAEP-256` but emit a warning that it is not quantum-resistant.
3. Support HSM-AES key type and AES-GCM wrapping
4. Support only client credentials oauth flow with Entra using clientId + clientSecret. This supports workloads running anywhere. We could add support for other client credentials (certificates, federated certs) and Managed Identities later. Share a single auth token per Filter Definition until near expiry.
5. Support TLS customization of the authentication client and key vault client.
6. DEK bytes will be generated proxy-side with a SecureRandom.
7. The Azure SDK pulls in netty/jackson/project-reactor, lets try implementing the APIs ourselves as we have for AWS
8. Edek stores the keyName, keyVersion, edek. We attempt to minimise keyVersion size by optimistically decoding it from hex string, else store the string.
9. User will supply tenantId for authentication, rather than implementing a more complicated workflow to obtain it using an HTTP request to KeyVault
### Configuration

```
kms: AzureKeyVault
kmsConfig:
  keyVaultBaseUri: https://kv-kfesiehfoieaf.vault.azure.net
  tls:
    ... client trust for key vault
  entraIdentity:
     oauthEndpointUrl: https://login.microsoftonline.com // optional defaults to this value
     clientId:
       passwordFile: /path/to/id
     clientSecret:
       passwordFile: /path/to/id
     tenantId: "abds-1232dsaa"
     scope: https://vault.azure.net/.default // optional, could infer from vaultBaseUri
     tls:
       ... client trust configuration for oauth
```
