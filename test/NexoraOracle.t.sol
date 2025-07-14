// SPDX-License-Identifier: MIT
pragma solidity  0.8.27;

import {Test,console} from "forge-std/Test.sol";
import {NexoraOracle} from "src/NexoraOracle.sol";

contract NexoraOracleTest is Test {

    NexoraOracle oracle;
    address temporaryOwner = address(0x11);

    function setUp() public{
        vm.prank(temporaryOwner);
        oracle = new NexoraOracle(false);
    }

    function test_checkIsOwnerInitialized() public {
        console.log(oracle.owner());
        assertEq(oracle.owner() ,address(0x11));
    }

}
