use alloy::sol;

sol!(
    #[allow(missing_docs)]
    #[sol(rpc)]
    OpenRankManager,
    concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../contracts/out/OpenRankManager.sol/OpenRankManager.json"
    )
);
