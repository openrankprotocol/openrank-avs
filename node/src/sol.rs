use alloy::sol;

sol!(
    #[allow(missing_docs)]
    #[sol(rpc)]
    OpenRankManager,
    "../contracts/out/OpenRankManager.sol/OpenRankManager.json"
);

sol!(
    #[allow(missing_docs)]
    #[sol(rpc)]
    ReexecutionEndpoint,
    "../contracts/out/ReexecutionEndpoint.sol/ReexecutionEndpoint.json"
);
