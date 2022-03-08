// SPDX-License-Identifier: Unlicense
pragma solidity ^0.6.11;

import {Vm} from "forge-std/Vm.sol";

contract MulticallRegistry {
    mapping(uint256 => address) private addresses;

    constructor() public {
        addresses[1] = 0xeefBa1e63905eF1D7ACbA5a8513c70307C1cE441;
        addresses[4] = 0x42Ad527de7d4e9d9d011aC45B31D8551f8Fe9821;
        addresses[5] = 0x77dCa2C955b15e9dE4dbBCf1246B4B85b651e50e;
        addresses[42] = 0x2cc8688C5f75E365aaEEb4ea8D6a480405A48D2A;
        addresses[56] = 0xeC8c00dA6ce45341FB8c31653B598Ca0d8251804;
        addresses[100] = 0xb5b692a88BDFc81ca69dcB1d924f59f0413A602a;
        addresses[250] = 0xb828C456600857abd4ed6C32FAcc607bD0464F4F;
        addresses[42161] = 0x7A7443F8c577d537f1d8cD4a629d40a3148Dd7ee;
    }

    function get(uint256 _chainId) public view returns (address multicall_) {
        multicall_ = addresses[_chainId];
        require(multicall_ != address(0), "Not in registry");
    }
}

abstract contract MulticallUtils {
    Vm constant vmUtils =
        Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // TODO: Default to 99?
    function getChainIdOfHead() public returns (uint256 chainId_) {
        string[] memory inputs = new string[](2);
        inputs[0] = "bash";
        inputs[1] = "scripts/chain-id.sh";
        chainId_ = abi.decode(vmUtils.ffi(inputs), (uint256));
    }

    // TODO: Deploy if not there?
    function getMulticall() public returns (address multicall_) {
        MulticallRegistry multicallRegistry = new MulticallRegistry();
        multicall_ = multicallRegistry.get(getChainIdOfHead());
    }
}

/*
TODO
- Custom errors
*/
