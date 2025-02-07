// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./common.sol";
import "../ScryToken.sol";

library verification {
    event RegisterVerifier(string seqNo, address[] users);
    event VoteResult(string seqNo, uint256 transactionId, bool judge, string comments, uint8 state, uint8 index, address[] users);
    event VerifierDisable(string seqNo, address verifier, address[] users);

    function register(common.DataSet storage ds, string memory seqNo, ERC20 token) public {
        common.Verifier storage v = getVerifier(ds.verifiers, msg.sender);
        require(v.addr == address(0x00), "Address already registered");

        //deposit
        if (ds.conf.verifierDepositToken > 0) {
            require(token.balanceOf(msg.sender) >= ds.conf.verifierDepositToken, "No enough balance");
            require(token.transferFrom(msg.sender, address(this), ds.conf.verifierDepositToken), "Pay deposit failed");
        }


        ds.verifiers.list.push(common.Verifier(msg.sender, ds.conf.verifierDepositToken, 0, 0, true));
        ds.verifiers.validVerifierCount++;

        address[] memory users = new address[](1);
        users[0] = msg.sender;
        emit RegisterVerifier(seqNo, users);
    }

    function vote(common.DataSet storage ds, string memory seqNo, uint txId, bool judge, string memory comments, ERC20 token) public {
        common.TransactionItem storage txItem = ds.txData.map[txId];
        require(txItem.used, "Transaction does not exist");
        require(txItem.state == common.TransactionState.Created || txItem.state == common.TransactionState.Voted, "Invalid transaction state");
        require(!ds.voteData.map[txId][msg.sender].used, "Verifier has voted");

        bool valid;
        uint8 index;
        common.Verifier storage verifier = getVerifier(ds.verifiers, msg.sender);
        (valid, index) = verifierValid(verifier, txItem.verifiers);
        require(valid, "Invalid verifier");

        payToVerifier(txItem, ds.conf.verifierBonus, verifier.addr, token);
        ds.voteData.map[txId][msg.sender] = common.VoteResult(judge, comments, true);

        txItem.state = common.TransactionState.Voted;
        txItem.creditGiven[index] = false;

        address[] memory users = new address[](1);
        users[0] = txItem.buyer;
        emit VoteResult(seqNo, txId, judge, comments, uint8(txItem.state), index+1, users);

        users[0] = msg.sender;
        emit VoteResult(seqNo, txId, judge, comments, uint8(txItem.state), 0, users);
    }

    function gradeToVerifier(common.DataSet storage ds, string memory seqNo, uint256 txId, uint8 verifierIndex, uint8 credit) public {
        //validate
        require(credit >= ds.conf.creditLow && credit <= ds.conf.creditHigh, "0 <= credit <= 5 is valid");

        common.TransactionItem storage txItem = ds.txData.map[txId];
        require(txItem.used, "Transaction does not exist");
        require(txItem.needVerify, "Transaction does not enter the verification process");

        common.DataInfoPublished storage data = ds.pubData.map[txItem.publishId];
        require(data.used, "Publish data does not exist");

        common.Verifier storage verifier = getVerifier(ds.verifiers, txItem.verifiers[verifierIndex]);
        require(verifier.addr != address(0x00), "Verifier does not exist");

        bool valid;
        uint256 index;
        (valid, index) = verifierValid(verifier, txItem.verifiers);
        require(valid, "Invalid verifier");
        require(!txItem.creditGiven[index], "This verifier is credited");

        verifier.credits = (uint8)((verifier.credits * verifier.creditTimes + credit)/(verifier.creditTimes+1));
        verifier.creditTimes++;
        txItem.creditGiven[index] = true;

        address[] memory users = new address[](1);
        users[0] = address(0x00);
        //disable verifier and forfeiture deposit while credit <= creditThreshold
        if (verifier.credits <= ds.conf.creditThreshold) {
            verifier.enable = false;
            verifier.deposit = 0;
            ds.verifiers.validVerifierCount--;
            require(ds.verifiers.validVerifierCount >= 1, "Invalid verifier count");

            emit VerifierDisable(seqNo, verifier.addr, users);
        }
    }

    function chooseVerifiers(common.DataSet storage ds, address seller) internal view returns (address[] memory) {
        require(ds.verifiers.validVerifierCount > ds.conf.verifierNum, "No enough valid verifiers");
        uint256 len = ds.verifiers.list.length;
        address[] memory chosenVerifiers = new address[](ds.conf.verifierNum);

        for (uint8 i = 0; i < ds.conf.verifierNum; i++) {
            uint256 index = uint256(keccak256(abi.encodePacked(block.timestamp, msg.sender))) % len;
            common.Verifier memory v = ds.verifiers.list[index];

            //loop if invalid verifier was chosen until get valid verifier
            address vb = v.addr;
            while (!v.enable || addressExist(chosenVerifiers, v.addr) || vb == seller || vb == msg.sender) {
                v = ds.verifiers.list[(++index) % len];
                require(v.addr != vb, "Disordered verifiers");
            }

            chosenVerifiers[i] = v.addr;
        }

        return chosenVerifiers;
    }

    function addressExist(address[] memory addrArray, address addr) internal pure returns (bool exist) {
        for (uint8 i = 0; i < addrArray.length; i++) {
            if (addr == addrArray[i]) {
                exist = true;
                break;
            }
        }

        return false;
    }

    function verifierValid(common.Verifier memory v, address[] memory arr) internal pure returns (bool, uint8) {
        bool exist;
        uint8 index;

        (exist, index) = addressIndex(arr, v.addr);
        return (v.enable && exist, index);
    }

    function verifierExist(address addr, address[] memory arr) internal pure returns (bool) {
        bool exist;
        (exist, ) = addressIndex(arr, addr);

        return exist;
    }

    function addressIndex(address[] memory addrArray, address addr) internal pure returns (bool, uint8) {
        for (uint8 i = 0; i < addrArray.length; i++) {
            if (addrArray[i] == addr) {
                return (true, i);
            }
        }

        return (false, 0);
    }

    function payToVerifier(common.TransactionItem storage txItem, uint256 amount, address verifier, ERC20 token) internal {
        if (txItem.buyerDeposit >= amount) {
            txItem.buyerDeposit -= amount;

            if (!token.transfer(verifier, amount)) {
                txItem.buyerDeposit += amount;
                require(false, "Failed to pay to verifier");
            }
        } else {
            require(false, "No enough deposit for verifier");
        }
    }

    function getVerifier(common.Verifiers storage self, address v) internal view returns (common.Verifier storage){
        for (uint256 i = 0; i < self.list.length; i++) {
            if (self.list[i].addr == v) {
                return self.list[i];
            }
        }

        return self.list[0];
    }

    function chooseArbitrators(common.DataSet storage ds, address[] memory vs, address seller) internal view returns (address[] memory) {
        uint256[] memory shortlistIndex = new uint256[](ds.verifiers.list.length - ds.conf.verifierNum);
        uint256 count;

        for (uint256 i = 0;i < ds.verifiers.list.length;i++) {
            common.Verifier storage a = ds.verifiers.list[i];
            if (arbitratorValid(a, ds.conf, vs) && a.addr != seller && a.addr != msg.sender) {
                shortlistIndex[count] = i;
                count++;
            }
        }
        require(count > ds.conf.arbitratorNum, "No enough valid arbitrators");

        uint256 shortlistLen = count;

        address[] memory shortlist = new address[](count);
        while (count > 0) {
            count--;
            shortlist[count] = ds.verifiers.list[shortlistIndex[count]].addr;
        }

        address[] memory chosenArbitrators = new address[](ds.conf.arbitratorNum);
        for (uint256 i = 0;i < ds.conf.arbitratorNum;i++) {
            uint256 index = uint256(keccak256(abi.encodePacked(block.timestamp, msg.sender))) % shortlistLen;
            address ad = shortlist[index];
            while (addressExist(chosenArbitrators, ad)) {
                ad = shortlist[(++index) % shortlistLen];
            }
            chosenArbitrators[i] = ad;
        }

        return chosenArbitrators;
    }

    function arbitratorValid(common.Verifier storage a, common.Configuration storage conf, address[] memory vs) internal view returns (bool) {
        bool notVerifier = true;
        for (uint8 i = 0;i < vs.length;i++) {
            if (a.addr == vs[i]) {
                notVerifier = false;
                break;
            }
        }
        return notVerifier && a.enable && (a.credits >= conf.arbitrateCredit);
    }

    function arbitrate(common.DataSet storage ds,uint256 txId, bool judge, ERC20 token) internal {
        common.TransactionItem storage txItem = ds.txData.map[txId];
        require(txItem.used, "Transaction does not exist");

        bool exist;
        uint8 index;
        (exist, index) = addressIndex(txItem.arbitrators, msg.sender);
        require(exist, "Invalid arbitrator");
        require(!ds.arbitratorData.map[txId][index].used, "Address already arbitrated");

        payToArbitrator(txItem, ds.conf.arbitratorBonus, msg.sender, token);
        ds.arbitratorData.map[txId][index] = common.ArbitratorResult(msg.sender, judge, true);
    }

    function arbitrateFinished(common.DataSet storage ds, uint256 txId) internal view returns (bool) {
        bool finish = true;
        for (uint8 i = 0; i < ds.conf.arbitratorNum; i++) {
            if (!ds.arbitratorData.map[txId][i].used) {
                finish = false;
                break;
            }
        }

        return finish;
    }

    function payToArbitrator(common.TransactionItem storage txItem, uint256 amount, address arbitrator, ERC20 token) internal {
        if (txItem.buyerDeposit >= amount) {
            txItem.buyerDeposit -= amount;

            if (!token.transfer(arbitrator, amount)) {
                txItem.buyerDeposit += amount;
                require(false, "Failed to pay to verifier");
            }
        } else {
            require(false, "No enough deposit for arbitrator");
        }
    }
}
