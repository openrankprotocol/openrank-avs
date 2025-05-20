# openrank-avs

## Steps to run:
1. Manually run Anavil on localhost:8545
2. ./scripts/deploy_openrank.sh
3. ./scripts/1_*.sh
4. ./scripts/2_*.sh
5. ./scripts/3_*.sh
6. ./scripts/4_*.sh
7. ./scripts/add_image_id.sh

To shutdown, use:
./scripts/shutdown.sh

### Openrank nodes
Install:
```bash
cargo install openrank-sdk --path ./sdk
cargo install openrank-node --path ./node
```

Run:
```bash
Node: openrank-node
Challanger: openrank-node --challanger
SDK command: openrank-sdk meta-compute-request ./datasets/trust/ ./datasets/seed/
```
