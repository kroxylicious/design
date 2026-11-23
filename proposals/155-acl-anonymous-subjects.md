# 155 - Rules for anonymous clients in the ACL authorizer

The ACL authorizer has no way to write a rule for a client that has not authenticated.
This proposal adds `anonymous` to the ACL rules format, selecting exactly those clients, and records where it deliberately departs from [proposal 009](./009-authorizer.md).

## Current situation

A client's identity is its *subject*: the set of facts the proxy has proven about it, each one a *principal*, such as `User["alice"]`.
A client that has not authenticated has a subject with no principals, which `Subject.anonymous()` returns.

ACL rules select subjects by principal: `allow User with name = "alice" to ...`.
Every rule needs a principal to match, so no rule can apply to an anonymous subject, and the ACL authorizer denies it everything.

Proposal 009 describes a selector for this case:

```
allow anonymous User to READ Topic with name = "foo";
```

where `anonymous User` means "none of the subject's principals are of type `User`".
It was never implemented: `anonymous` is not part of the grammar.

## Motivation

Some deployments allow unauthenticated access to a few resources, for example public topics, or public schemas in Apicurio Registry, which uses the ACL rules format for per-resource authorization.
Today they cannot express that in ACL rules at all.

The meaning in proposal 009 is not the right one for this, though.
"No principal of type `User`" also matches a client that authenticated as something else: with `User` and `ServiceAccount` principals, `Subject[{ServiceAccount["billing"]}]` has no `User`, so `allow anonymous User ...` would apply to it, and `deny anonymous User ...` would deny it.
A rule written for unauthenticated clients would silently apply to authenticated ones too.
It also treats "anonymous" as a fact about one principal type, when a subject is a set of proven facts, and "anonymous" means that nothing has been proven.
That meaning already exists, `Subject.anonymous()`, and every authorizer should share it.

## Proposal

Add `anonymous` as an alternative to the principal selector in allow and deny rules:

```
deny anonymous to READ Topic with name = "public-secret";
allow anonymous to READ Topic with name like "public-*";
```

- `anonymous` selects only the subject with no principals, as returned by `Subject.anonymous()`.
  It takes no principal type.
- An `anonymous` rule never applies to a subject with any principal, and no other rule applies to the anonymous subject.
  So `allow User with name * ...` still does not grant anything to unauthenticated clients.
- Deny rules work as for any other selector: a matching deny wins over a matching allow.
- The builder API gains a matching method, `anonymousSubjects()`, next to `subjectsHavingPrincipal(...)`.

### Departure from proposal 009

This replaces the `anonymous <PrincipalType>` selector of proposal 009.
The type is dropped, and the selector matches the anonymous subject only, for the reasons under Motivation.
Proposal 009 is not changed; this proposal records the difference.

## Affected/not affected projects

- `kroxylicious`: the ACL authorizer (`kroxylicious-authorizer-acl`): grammar, rule evaluation, builder API, documentation.
- The `Authorizer` API is not affected: `Subject.anonymous()` already exists.
- Other authorizers are not affected.

## Compatibility

- Existing rules files keep their meaning: none can contain an `anonymous` rule today.
- `anonymous` becomes a keyword of the rules format.
  A file that uses `anonymous` as the alias of an imported type (`import User as anonymous`) needs another alias.
- If principals that are not about identity are ever added to subjects, for example the client's network address, unauthenticated clients would no longer have an empty subject, and `anonymous` rules would stop matching them.
  This proposal ties `anonymous` to `Subject.anonymous()` so that such a change has to decide, in one place, what anonymous means.

## Rejected alternatives

- **Implement proposal 009 as written** (`anonymous User` = no principal of type `User`).
  Rules meant for unauthenticated clients would also apply to clients authenticated with another principal type, as described under Motivation.
- **Keep the type, but match only the anonymous subject** (`anonymous User` = no principals).
  The type would then be ignored, and the syntax would suggest a type check that isn't there.
- **No syntax; applications give unauthenticated clients a made-up principal**, such as a role named `$anonymous`.
  That works in a single application, but it is a fact nobody proved, every application has to invent its own, and rules files that look shared would mean different things in each.
