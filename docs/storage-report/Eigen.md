| Name                              | Type                                                          | Slot | Offset | Bytes | Contract                            |
|-----------------------------------|---------------------------------------------------------------|------|--------|-------|-------------------------------------|
| _initialized                      | uint8                                                         | 0    | 0      | 1     | src/contracts/token/Eigen.sol:Eigen |
| _initializing                     | bool                                                          | 0    | 1      | 1     | src/contracts/token/Eigen.sol:Eigen |
| __gap                             | uint256[50]                                                   | 1    | 0      | 1600  | src/contracts/token/Eigen.sol:Eigen |
| _owner                            | address                                                       | 51   | 0      | 20    | src/contracts/token/Eigen.sol:Eigen |
| __gap                             | uint256[49]                                                   | 52   | 0      | 1568  | src/contracts/token/Eigen.sol:Eigen |
| _balances                         | mapping(address => uint256)                                   | 101  | 0      | 32    | src/contracts/token/Eigen.sol:Eigen |
| _allowances                       | mapping(address => mapping(address => uint256))               | 102  | 0      | 32    | src/contracts/token/Eigen.sol:Eigen |
| _totalSupply                      | uint256                                                       | 103  | 0      | 32    | src/contracts/token/Eigen.sol:Eigen |
| _name                             | string                                                        | 104  | 0      | 32    | src/contracts/token/Eigen.sol:Eigen |
| _symbol                           | string                                                        | 105  | 0      | 32    | src/contracts/token/Eigen.sol:Eigen |
| __gap                             | uint256[45]                                                   | 106  | 0      | 1440  | src/contracts/token/Eigen.sol:Eigen |
| _hashedName                       | bytes32                                                       | 151  | 0      | 32    | src/contracts/token/Eigen.sol:Eigen |
| _hashedVersion                    | bytes32                                                       | 152  | 0      | 32    | src/contracts/token/Eigen.sol:Eigen |
| _name                             | string                                                        | 153  | 0      | 32    | src/contracts/token/Eigen.sol:Eigen |
| _version                          | string                                                        | 154  | 0      | 32    | src/contracts/token/Eigen.sol:Eigen |
| __gap                             | uint256[48]                                                   | 155  | 0      | 1536  | src/contracts/token/Eigen.sol:Eigen |
| _nonces                           | mapping(address => struct CountersUpgradeable.Counter)        | 203  | 0      | 32    | src/contracts/token/Eigen.sol:Eigen |
| _PERMIT_TYPEHASH_DEPRECATED_SLOT  | bytes32                                                       | 204  | 0      | 32    | src/contracts/token/Eigen.sol:Eigen |
| __gap                             | uint256[49]                                                   | 205  | 0      | 1568  | src/contracts/token/Eigen.sol:Eigen |
| _delegates                        | mapping(address => address)                                   | 254  | 0      | 32    | src/contracts/token/Eigen.sol:Eigen |
| _checkpoints                      | mapping(address => struct ERC20VotesUpgradeable.Checkpoint[]) | 255  | 0      | 32    | src/contracts/token/Eigen.sol:Eigen |
| _totalSupplyCheckpoints           | struct ERC20VotesUpgradeable.Checkpoint[]                     | 256  | 0      | 32    | src/contracts/token/Eigen.sol:Eigen |
| __gap                             | uint256[47]                                                   | 257  | 0      | 1504  | src/contracts/token/Eigen.sol:Eigen |
| mintAllowedAfter                  | mapping(address => uint256)                                   | 304  | 0      | 32    | src/contracts/token/Eigen.sol:Eigen |
| mintingAllowance                  | mapping(address => uint256)                                   | 305  | 0      | 32    | src/contracts/token/Eigen.sol:Eigen |
| transferRestrictionsDisabledAfter | uint256                                                       | 306  | 0      | 32    | src/contracts/token/Eigen.sol:Eigen |
| allowedFrom                       | mapping(address => bool)                                      | 307  | 0      | 32    | src/contracts/token/Eigen.sol:Eigen |
| allowedTo                         | mapping(address => bool)                                      | 308  | 0      | 32    | src/contracts/token/Eigen.sol:Eigen |
