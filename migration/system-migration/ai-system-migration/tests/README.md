# Tests

Basic smoke test:

```bash
python3 bin/ai_system_migration.py init --workspace /tmp/ai-system-migration-test
python3 bin/ai_system_migration.py run --config config/templates/migration_config.yaml --dry-run
```

The run command is conservative and dry-run by default in this skeleton.
