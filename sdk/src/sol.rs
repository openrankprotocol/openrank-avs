use alloy::sol;

sol!(
    #[allow(missing_docs)]
    #[sol(rpc)]
    OpenRankManager,
    "contracts/OpenRankManager.sol/OpenRankManager.json"
);

sol!(
    #[allow(missing_docs)]
    #[sol(rpc)]
    ReexecutionEndpoint,
    "contracts/ReexecutionEndpoint.sol/ReexecutionEndpoint.json"
);
