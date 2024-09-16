| Name                                 | Type                                                    | Slot | Offset | Bytes | Contract                                                     |
|--------------------------------------|---------------------------------------------------------|------|--------|-------|--------------------------------------------------------------|
| _initialized                         | uint8                                                   | 0    | 0      | 1     | src/contracts/core/RewardsCoordinator.sol:RewardsCoordinator |
| _initializing                        | bool                                                    | 0    | 1      | 1     | src/contracts/core/RewardsCoordinator.sol:RewardsCoordinator |
| __gap                                | uint256[50]                                             | 1    | 0      | 1600  | src/contracts/core/RewardsCoordinator.sol:RewardsCoordinator |
| _owner                               | address                                                 | 51   | 0      | 20    | src/contracts/core/RewardsCoordinator.sol:RewardsCoordinator |
| __gap                                | uint256[49]                                             | 52   | 0      | 1568  | src/contracts/core/RewardsCoordinator.sol:RewardsCoordinator |
| pauserRegistry                       | contract IPauserRegistry                                | 101  | 0      | 20    | src/contracts/core/RewardsCoordinator.sol:RewardsCoordinator |
| _paused                              | uint256                                                 | 102  | 0      | 32    | src/contracts/core/RewardsCoordinator.sol:RewardsCoordinator |
| __gap                                | uint256[48]                                             | 103  | 0      | 1536  | src/contracts/core/RewardsCoordinator.sol:RewardsCoordinator |
| _status                              | uint256                                                 | 151  | 0      | 32    | src/contracts/core/RewardsCoordinator.sol:RewardsCoordinator |
| __gap                                | uint256[49]                                             | 152  | 0      | 1568  | src/contracts/core/RewardsCoordinator.sol:RewardsCoordinator |
| _DOMAIN_SEPARATOR                    | bytes32                                                 | 201  | 0      | 32    | src/contracts/core/RewardsCoordinator.sol:RewardsCoordinator |
| _distributionRoots                   | struct IRewardsCoordinator.DistributionRoot[]           | 202  | 0      | 32    | src/contracts/core/RewardsCoordinator.sol:RewardsCoordinator |
| rewardsUpdater                       | address                                                 | 203  | 0      | 20    | src/contracts/core/RewardsCoordinator.sol:RewardsCoordinator |
| activationDelay                      | uint32                                                  | 203  | 20     | 4     | src/contracts/core/RewardsCoordinator.sol:RewardsCoordinator |
| currRewardsCalculationEndTimestamp   | uint32                                                  | 203  | 24     | 4     | src/contracts/core/RewardsCoordinator.sol:RewardsCoordinator |
| globalOperatorCommissionBips         | uint16                                                  | 203  | 28     | 2     | src/contracts/core/RewardsCoordinator.sol:RewardsCoordinator |
| claimerFor                           | mapping(address => address)                             | 204  | 0      | 32    | src/contracts/core/RewardsCoordinator.sol:RewardsCoordinator |
| cumulativeClaimed                    | mapping(address => mapping(contract IERC20 => uint256)) | 205  | 0      | 32    | src/contracts/core/RewardsCoordinator.sol:RewardsCoordinator |
| submissionNonce                      | mapping(address => uint256)                             | 206  | 0      | 32    | src/contracts/core/RewardsCoordinator.sol:RewardsCoordinator |
| isAVSRewardsSubmissionHash           | mapping(address => mapping(bytes32 => bool))            | 207  | 0      | 32    | src/contracts/core/RewardsCoordinator.sol:RewardsCoordinator |
| isRewardsSubmissionForAllHash        | mapping(address => mapping(bytes32 => bool))            | 208  | 0      | 32    | src/contracts/core/RewardsCoordinator.sol:RewardsCoordinator |
| isRewardsForAllSubmitter             | mapping(address => bool)                                | 209  | 0      | 32    | src/contracts/core/RewardsCoordinator.sol:RewardsCoordinator |
| isRewardsSubmissionForAllEarnersHash | mapping(address => mapping(bytes32 => bool))            | 210  | 0      | 32    | src/contracts/core/RewardsCoordinator.sol:RewardsCoordinator |
| __gap                                | uint256[39]                                             | 211  | 0      | 1248  | src/contracts/core/RewardsCoordinator.sol:RewardsCoordinator |