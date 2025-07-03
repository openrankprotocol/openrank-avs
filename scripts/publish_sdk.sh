CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

cp "$CURRENT_DIR/../contracts/out/OpenRankManager.sol/OpenRankManager.json" "$CURRENT_DIR/contracts/OpenRankManager.sol/OpenRankManager.json"

cargo publish -p openrank-sdk
