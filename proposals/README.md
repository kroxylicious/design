# Kroxylicious Proposals

This directory contains proposals for the Kroxylicious project.

## Creating a New Proposal

1. **Create your proposal file** using a placeholder name based on the [template](./000-template.md):
   ```
   proposals/000-<descriptive-name>.md
   ```

2. **Commit and open a Pull Request**:
   - Push your branch and open a PR on GitHub
   - Note your PR number (e.g., #105)

3. **Rename the file** to use your PR number (three-digit zero-padded):
   ```bash
   git mv proposals/000-<descriptive-name>.md proposals/105-<descriptive-name>.md
   git commit -m "Rename proposal to use PR number"
   git push
   ```

4. **Announce** your proposal on the [mailing list](https://kroxylicious.io/join-us/mailing-lists/)

When your proposal is **accepted and merged**, the proposal number remains the same as the PR number.

## Finding Proposals

- **All proposals:** Browse the directory listing above
- **Open proposals:** [View open proposal PRs](https://github.com/kroxylicious/design/pulls?q=is%3Apr+is%3Aopen+label%3Aproposal)
- **Merged proposals:** Proposal files in this directory (sorted alphabetically)

## Numbering

Proposal numbers match PR numbers, using three-digit zero-padding (e.g., `092-`, `105-`).

Proposals 001-019 predate this system and retain their original numbers.
