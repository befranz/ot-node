pragma solidity ^0.4.25;

import {SafeMath} from "./SafeMath.sol";
import {ERC725} from './ERC725.sol';
import {Hub} from "./Hub.sol";
import {Holding} from "./Holding.sol";
import {HoldingStorage} from "./HoldingStorage.sol";
import {ProfileStorage} from "./ProfileStorage.sol";
import {LitigationStorage} from "./LitigationStorage.sol";

contract Litigation {
    using SafeMath for uint256;

    Hub public hub;

    constructor (address hubAddress) public {
        hub = Hub(hubAddress);
    }

    function setHubAddress(address newHubAddress) public {
        require(hub.isContract(msg.sender), "This function can only be called by contracts or their creator!");

        hub = Hub(newHubAddress);
    }

	/*    ----------------------------- LITIGATION -----------------------------     */
    event LitigationStatusChanged(bytes32 offerId, address holderIdentity, LitigationStorage.LitigationStatus status);

    event ReplacementStarted(bytes32 offerId, address holderIdentity, address challengerIdentity, bytes32 litigationRootHash);
    event ReplacementCompleted(bytes32 offerId, address challengerIdentity, address chosenHolder);

    function initiateLitigation(bytes32 offerId, address holderIdentity, address challengerIdentity, uint requestedDataIndex, bytes32[] hashArray)
    public returns (bool newLitigationInitiated){
        HoldingStorage holdingStorage = HoldingStorage(hub.holdingStorageAddress());
        LitigationStorage litigationStorage = LitigationStorage(hub.litigationStorageAddress());
        require(holdingStorage.getOfferCreator(offerId) == challengerIdentity, "Challenger identity not equal to offer creator identity!");
        require(ERC725(challengerIdentity).keyHasPurpose(keccak256(abi.encodePacked(msg.sender)),2), "Sender does not have action purpose set!");

        LitigationStorage.LitigationStatus litigationStatus = litigationStorage.getLitigationStatus(offerId, holderIdentity);

        uint256 timestamp = litigationStorage.getLitigationTimestamp(offerId, holderIdentity);
        uint256 litigationIntervalInSeconds = holdingStorage.getOfferLitigationIntervalInMinutes(offerId).mul(60);

        require(litigationStatus != LitigationStorage.LitigationStatus.replacing,
            "The selected holder is already being replaced, cannot initiate litigation!");
        require(litigationStatus != LitigationStorage.LitigationStatus.replaced,
            "The selected holder is already replaced, cannot initiate litigation!");

        if(litigationStatus == LitigationStorage.LitigationStatus.initiated) {
            require(timestamp + litigationIntervalInSeconds.mul(3) < block.timestamp, 
                "The litigation is initiated and awaiting holder response, cannot initiate another litigation!");
        } else if(litigationStatus == LitigationStorage.LitigationStatus.answered) {
            require(timestamp + litigationIntervalInSeconds.mul(2) < block.timestamp, 
                "The litigation is answered and awaiting previous litigator response, cannot initiate another litigation!");
        } else if(litigationStatus == LitigationStorage.LitigationStatus.initiated) {
            require(timestamp + litigationIntervalInSeconds < block.timestamp, 
                "The litigation interval has not passed yet, cannot initiate another litigation!");
        }

        // Write litigation information into the storage
        litigationStorage.setLitigationLitigatorIdentity(offerId, holderIdentity, challengerIdentity);
        litigationStorage.setLitigationRequestedDataIndex(offerId, holderIdentity, requestedDataIndex);
        litigationStorage.setLitigationHashArray(offerId, holderIdentity, hashArray);
        
        litigationStorage.setLitigationStatus(offerId, holderIdentity, LitigationStorage.LitigationStatus.initiated);
        litigationStorage.setLitigationTimestamp(offerId, holderIdentity, block.timestamp);

        emit LitigationStatusChanged(offerId, holderIdentity, LitigationStorage.LitigationStatus.initiated);
        return true;
    }
    
    function answerLitigation(bytes32 offerId, address holderIdentity, bytes32 requestedData)
    public returns (bool answer_accepted){
        HoldingStorage holdingStorage = HoldingStorage(hub.holdingStorageAddress());
        LitigationStorage litigationStorage = LitigationStorage(hub.litigationStorageAddress());
        require(ERC725(holderIdentity).keyHasPurpose(keccak256(abi.encodePacked(msg.sender)),2), "Sender does not have action purpose set!");

        LitigationStorage.LitigationStatus litigationStatus = litigationStorage.getLitigationStatus(offerId, holderIdentity);

        require(litigationStatus == LitigationStorage.LitigationStatus.initiated, 
            "Litigation status is not set to initiated, cannot send answer!");
        require(litigationStorage.getLitigationTimestamp(offerId, holderIdentity) + holdingStorage.getOfferLitigationIntervalInMinutes(offerId).mul(60) >= block.timestamp, 
            "The interval for answering has passed, cannot answer litigation!");

        // Write answer data into the hash
        litigationStorage.setLitigationRequestedData(offerId, holderIdentity, keccak256(requestedData, litigationStorage.getLitigationRequestedDataIndex(offerId, holderIdentity)));

        litigationStorage.setLitigationStatus(offerId, holderIdentity, LitigationStorage.LitigationStatus.answered);
        litigationStorage.setLitigationTimestamp(offerId, holderIdentity, block.timestamp);

        emit LitigationStatusChanged(offerId, holderIdentity, LitigationStorage.LitigationStatus.answered);
        return true;
    }

    // TODO Add the functionalities of cancel inactive litigation function into the payOut function

    // /**
    // * @dev Allows the DH to mark a litigation as completed in order to call payOut.
    // * Used only when DC is inactive after DH sent litigation answer.
    // */
    // function cancelInactiveLitigation(bytes32 offerId)
    // public{
    //     LitigationDefinition storage this_litigation = litigation[offerId][msg.sender];

    //     require(this_litigation.litigation_status == LitigationStatus.answered, "Litigation status must be answered");
    //     require(this_litigation.answer_timestamp + 15 minutes <= block.timestamp,
    //         "Function cannot be called within 15 minutes after answering litigation");

    //     this_litigation.litigation_status = LitigationStatus.completed;
    //     emit LitigationCompleted(offerId, msg.sender, false);

    // }

    function completeLitigation(bytes32 offerId, address holderIdentity, address litigatorIdentity, bytes32 proofData)
    public returns (bool DH_was_penalized){
        HoldingStorage holdingStorage = HoldingStorage(hub.holdingStorageAddress());
        LitigationStorage litigationStorage = LitigationStorage(hub.litigationStorageAddress());
        ProfileStorage profileStorage = ProfileStorage(hub.profileStorageAddress());
        
        require(holdingStorage.getOfferCreator(offerId) == litigatorIdentity, "Challenger identity not equal to offer creator identity!");
        require(ERC725(litigatorIdentity).keyHasPurpose(keccak256(abi.encodePacked(msg.sender)),2), "Sender does not have action purpose set!");
        require(litigationStorage.getLitigationLitigatorIdentity(offerId, holderIdentity) == litigatorIdentity, "Litigation can only be completed by the litigator who initiated the litigation!");

        uint256[] memory parameters = new uint256[](4);

        // set parameters[0] as the last litigation timestamp
        parameters[0] = litigationStorage.getLitigationTimestamp(offerId, holderIdentity);
        // set parameters[1] as the litigation interval in seconds
        parameters[1] = holdingStorage.getOfferLitigationIntervalInMinutes(offerId).mul(60);

       	LitigationStorage.LitigationStatus litigationStatus = litigationStorage.getLitigationStatus(offerId, holderIdentity);

        require(litigationStatus != LitigationStorage.LitigationStatus.replacing,
            "The selected holder is already being replaced, cannot call this function!");
        require(litigationStatus != LitigationStorage.LitigationStatus.replaced,
            "The selected holder is already replaced, cannot call this function!");
        require(litigationStatus != LitigationStorage.LitigationStatus.completed,
            "Cannot complete a comlpeted litigation that is not initiated or answered!");

        if(holdingStorage.getHolderLitigationEncryptionType(offerId, holderIdentity) == 0){
            parameters[3] = uint256(litigationStorage.getLitigationRequestedData(offerId, holderIdentity));
        } else if (holdingStorage.getHolderLitigationEncryptionType(offerId, holderIdentity) == 1) {
            parameters[3] = uint256(holdingStorage.getOfferGreenLitigationHash(offerId));
        } else {
            parameters[3] = uint256(holdingStorage.getOfferBlueLitigationHash(offerId));
        }

        if(litigationStatus == LitigationStorage.LitigationStatus.initiated) {
            require(parameters[0] + parameters[1].mul(2) >= block.timestamp, 
                "The time window for completing the unanswered litigation has passed!");
            require(parameters[0] + parameters[1] < block.timestamp, 
                "The answer window has not passed, cannot complete litigation yet!");
        } else if(litigationStatus == LitigationStorage.LitigationStatus.answered) {
            require(parameters[0] + parameters[1] >= block.timestamp, 
                "The time window for completing the answered litigation has passed!");
            // Pay the previous holder
            parameters[0] = holdingStorage.getOfferTokenAmountPerHolder(offerId);
            parameters[0] = parameters[0].mul(block.timestamp.sub(holdingStorage.getHolderPaymentTimestamp(offerId, holderIdentity)));
            parameters[0] = parameters[0].div(holdingStorage.getOfferHoldingTimeInMinutes(offerId).mul(60));

            require(holdingStorage.getHolderPaidAmount(offerId, holderIdentity).add(parameters[0]) < holdingStorage.getHolderStakedAmount(offerId, holderIdentity),
                "Holder considered to successfully completed offer, cannot complete litigation!");

            profileStorage.setStake(holderIdentity, profileStorage.getStake(holderIdentity).add(parameters[0]));
            parameters[1] = profileStorage.getStake(holdingStorage.getOfferCreator(offerId));
            profileStorage.setStake(holdingStorage.getOfferCreator(offerId), parameters[1].sub(parameters[0]));
            parameters[1] = profileStorage.getStakeReserved(holdingStorage.getOfferCreator(offerId));
            profileStorage.setStakeReserved(holdingStorage.getOfferCreator(offerId), parameters[1].sub(parameters[0])); 
            parameters[1] = holdingStorage.getHolderPaidAmount(offerId, holderIdentity);
            holdingStorage.setHolderPaidAmount(offerId, holderIdentity, parameters[1].add(parameters[0]));

            litigationStorage.setLitigationStatus(offerId, holderIdentity, LitigationStorage.LitigationStatus.replacing);
            litigationStorage.setLitigationTimestamp(offerId, holderIdentity, block.timestamp);

            if(holdingStorage.getDifficultyOverride() != 0) parameters[2] = holdingStorage.getDifficultyOverride();
            else {
                if(logs2(profileStorage.activeNodes()) <= 4) parameters[2] = 1;
                else {
                    parameters[2] = 4 + (((logs2(profileStorage.activeNodes()) - 4) * 10000) / 13219);
                }
            }
            litigationStorage.setLitigationReplacementDifficulty(offerId, holderIdentity, parameters[2]);
                // Calculate and set task
            litigationStorage.setLitigationReplacementTask(offerId, holderIdentity, blockhash(block.number - 1) & bytes32(2 ** (parameters[2] * 4) - 1));

            emit LitigationStatusChanged(offerId, holderIdentity, LitigationStorage.LitigationStatus.replacing);
            emit ReplacementStarted(offerId, holderIdentity, litigatorIdentity, bytes32(parameters[3]));
            return true;
        }

        if(calculateMerkleTrees(offerId, holderIdentity, proofData, bytes32(parameters[3]))) {
            // DH has the requested data -> Set litigation as completed, no transfer of tokens
            litigationStorage.setLitigationStatus(offerId, holderIdentity, LitigationStorage.LitigationStatus.completed);
            litigationStorage.setLitigationTimestamp(offerId, holderIdentity, block.timestamp);
            

            emit LitigationStatusChanged(offerId, holderIdentity, LitigationStorage.LitigationStatus.completed);
            return false;
        }
        else {
            // DH didn't have the requested data, and the litigation was valid
            //        -> Distribute tokens and send stake to DC

            // Pay the previous holder
            parameters[0] = holdingStorage.getOfferTokenAmountPerHolder(offerId);
            parameters[0] = parameters[0].mul(block.timestamp.sub(holdingStorage.getHolderPaymentTimestamp(offerId, holderIdentity)));
            parameters[0] = parameters[0].div(holdingStorage.getOfferHoldingTimeInMinutes(offerId).mul(60));

            require(holdingStorage.getHolderPaidAmount(offerId, holderIdentity).add(parameters[0]) < holdingStorage.getHolderStakedAmount(offerId, holderIdentity),
                "Holder considered to successfully completed offer, cannot complete litigation!");

            profileStorage.setStake(holderIdentity, profileStorage.getStake(holderIdentity).add(parameters[0]));
            parameters[1] = profileStorage.getStake(holdingStorage.getOfferCreator(offerId));
            profileStorage.setStake(holdingStorage.getOfferCreator(offerId), parameters[1].sub(parameters[0]));
            parameters[1] = profileStorage.getStakeReserved(holdingStorage.getOfferCreator(offerId));
            profileStorage.setStakeReserved(holdingStorage.getOfferCreator(offerId), parameters[1].sub(parameters[0])); 
            parameters[1] = holdingStorage.getHolderPaidAmount(offerId, holderIdentity);
            holdingStorage.setHolderPaidAmount(offerId, holderIdentity, parameters[1].add(parameters[0]));

            litigationStorage.setLitigationStatus(offerId, holderIdentity, LitigationStorage.LitigationStatus.replacing);
            litigationStorage.setLitigationTimestamp(offerId, holderIdentity, block.timestamp);


            // Set new offer parameters
                // Calculate and set difficulty
            if(holdingStorage.getDifficultyOverride() != 0) parameters[2] = holdingStorage.getDifficultyOverride();
            else {
                if(logs2(profileStorage.activeNodes()) <= 4) parameters[2] = 1;
                else {
                    parameters[2] = 4 + (((logs2(profileStorage.activeNodes()) - 4) * 10000) / 13219);
                }
            }
            litigationStorage.setLitigationReplacementDifficulty(offerId, holderIdentity, parameters[2]);
                // Calculate and set task
            litigationStorage.setLitigationReplacementTask(offerId, holderIdentity, blockhash(block.number - 1) & bytes32(2 ** (parameters[2] * 4) - 1));

            emit LitigationStatusChanged(offerId, holderIdentity, LitigationStorage.LitigationStatus.replacing);
            emit ReplacementStarted(offerId, holderIdentity, litigatorIdentity, bytes32(parameters[3]));
            return true;
        }
    }

    function calculateMerkleTrees(bytes32 offerId, address holderIdentity, bytes32 proofData, bytes32 litigationRootHash)
    internal returns (bool DHAnsweredCorrectly) {
        LitigationStorage litigationStorage = LitigationStorage(hub.litigationStorageAddress());
        
        uint256 i = 0;
        uint256 mask = 1;
        uint256 requestedDataIndex = litigationStorage.getLitigationRequestedDataIndex(offerId, holderIdentity);
        bytes32 answerHash = litigationStorage.getLitigationRequestedData(offerId, holderIdentity);
        bytes32 proofHash = keccak256(abi.encodePacked(proofData, requestedDataIndex));
        bytes32[] memory hashArray = litigationStorage.getLitigationHashArray(offerId, holderIdentity);

        // ako je bit 1 on je levo
        while (i < hashArray.length){
            if( ((mask << i) & requestedDataIndex) != 0 ){
                proofHash = keccak256(abi.encodePacked(hashArray[i], proofHash));
                answerHash = keccak256(abi.encodePacked(hashArray[i], answerHash));
            }
            else {
                proofHash = keccak256(abi.encodePacked(proofHash, hashArray[i]));
                answerHash = keccak256(abi.encodePacked(answerHash, hashArray[i]));
            }
            i++;
        }    
        return (answerHash == litigationRootHash || proofHash != litigationRootHash);
    }

    function replaceHolder(bytes32 offerId, address holderIdentity, address litigatorIdentity, uint256 shift,
        bytes confirmation1, bytes confirmation2, bytes confirmation3, address[] replacementHolderIdentity)
    public {
        HoldingStorage holdingStorage = HoldingStorage(hub.holdingStorageAddress());
        LitigationStorage litigationStorage = LitigationStorage(hub.litigationStorageAddress());
        
        require(holdingStorage.getOfferCreator(offerId) == litigatorIdentity, "Challenger identity not equal to offer creator identity!");
        require(ERC725(litigatorIdentity).keyHasPurpose(keccak256(abi.encodePacked(msg.sender)), 2), "Sender does not have action purpose set!");
        require(litigationStorage.getLitigationLitigatorIdentity(offerId, holderIdentity) == litigatorIdentity, "Holder can only be replaced by the litigator who initiated the litigation!");

        LitigationStorage.LitigationStatus litigationStatus = litigationStorage.getLitigationStatus(offerId, holderIdentity);

        require(litigationStatus == LitigationStorage.LitigationStatus.replacing, "Litigation not in status replacing, cannot replace holder!");

        // Check if signatures match identities
        require(ERC725(replacementHolderIdentity[0]).keyHasPurpose(keccak256(abi.encodePacked(ecrecovery(keccak256(abi.encodePacked(offerId,uint256(replacementHolderIdentity[0]))), confirmation1))), 4), "Wallet from holder 1 does not have encryption approval!");
        require(ERC725(replacementHolderIdentity[1]).keyHasPurpose(keccak256(abi.encodePacked(ecrecovery(keccak256(abi.encodePacked(offerId,uint256(replacementHolderIdentity[1]))), confirmation2))), 4), "Wallet from holder 2 does not have encryption approval!");
        require(ERC725(replacementHolderIdentity[2]).keyHasPurpose(keccak256(abi.encodePacked(ecrecovery(keccak256(abi.encodePacked(offerId,uint256(replacementHolderIdentity[2]))), confirmation3))), 4), "Wallet from holder 3 does not have encryption approval!");

        // Verify task answer
        require(((keccak256(abi.encodePacked(replacementHolderIdentity[0], replacementHolderIdentity[1], replacementHolderIdentity[2])) >> (shift * 4)) & bytes32((2 ** (4 * holdingStorage.getOfferDifficulty(bytes32(offerId)))) - 1))
        == holdingStorage.getOfferTask(bytes32(offerId)), "Submitted identities do not answer the task correctly!");

        // Set litigation status
        litigationStorage.setLitigationStatus(offerId, holderIdentity, LitigationStorage.LitigationStatus.replaced);
        emit LitigationStatusChanged(offerId, holderIdentity, LitigationStorage.LitigationStatus.replaced);
        emit ReplacementCompleted(offerId, litigatorIdentity, replacementHolderIdentity[block.timestamp % 3]);
    }

    function setUpHolders(bytes32 offerId, address holderIdentity, address litigatorIdentity, address replacementHolderIdentity)
    internal {
        ProfileStorage profileStorage = ProfileStorage(hub.profileStorageAddress());
        HoldingStorage holdingStorage = HoldingStorage(hub.holdingStorageAddress());

        holdingStorage.setHolderLitigationEncryptionType(offerId, replacementHolderIdentity, holdingStorage.getHolderLitigationEncryptionType(offerId, holderIdentity));
        holdingStorage.setHolderLitigationEncryptionType(offerId, litigatorIdentity, holdingStorage.getHolderLitigationEncryptionType(offerId, holderIdentity));

        uint256 stakedAmount = holdingStorage.getHolderStakedAmount(offerId, holderIdentity).sub(holdingStorage.getHolderPaidAmount(offerId, holderIdentity));
        // Reserve new holder stakes in their profiles
        profileStorage.setStakeReserved(replacementHolderIdentity, profileStorage.getStakeReserved(replacementHolderIdentity).add(stakedAmount));
        profileStorage.setStakeReserved(litigatorIdentity, profileStorage.getStakeReserved(litigatorIdentity).add(stakedAmount));
        // Set new holder staked amounts
        holdingStorage.setHolderStakedAmount(offerId, replacementHolderIdentity, stakedAmount);
        holdingStorage.setHolderStakedAmount(offerId, litigatorIdentity, stakedAmount);

        // Pay the litigator
        profileStorage.setStake(litigatorIdentity, profileStorage.getStake(litigatorIdentity).add(holdingStorage.getHolderPaidAmount(offerId, holderIdentity)));
        profileStorage.setStake(holderIdentity, profileStorage.getStake(holderIdentity).sub(holdingStorage.getHolderPaidAmount(offerId, holderIdentity)));
        profileStorage.setStakeReserved(holderIdentity, profileStorage.getStakeReserved(holderIdentity).sub(holdingStorage.getHolderPaidAmount(offerId, holderIdentity)));

        // Set payment timestamps for new holders
        holdingStorage.setHolderPaymentTimestamp(offerId, replacementHolderIdentity, block.timestamp);
        holdingStorage.setHolderPaymentTimestamp(offerId, litigatorIdentity, block.timestamp);

    }

    function ecrecovery(bytes32 hash, bytes sig) internal pure returns (address) {
        bytes32 r;
        bytes32 s;
        uint8 v;

        if (sig.length != 65)
          return address(0);

        bytes memory prefix = "\x19Ethereum Signed Message:\n32";
        bytes32 prefixedHash = keccak256(abi.encodePacked(prefix, hash));
  
        // The signature format is a compact form of:
        //   {bytes32 r}{bytes32 s}{uint8 v}
        // Compact means, uint8 is not padded to 32 bytes.
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))

            // Here we are loading the last 32 bytes. We exploit the fact that
            // 'mload' will pad with zeroes if we overread.
            // There is no 'mload8' to do this, but that would be nicer.
            v := byte(0, mload(add(sig, 96)))
        }

        // geth uses [0, 1] and some clients have followed. This might change, see:
        //  https://github.com/ethereum/go-ethereum/issues/2053
        if (v < 27) v += 27;

        if (v != 27 && v != 28) return address(0);

        return ecrecover(prefixedHash, v, r, s);
    }

    function logs2(uint x) internal pure returns (uint y){
        require(x > 0, "log(0) not allowed");
        assembly {
            let arg := x
            x := sub(x,1)
            x := or(x, div(x, 0x02))
            x := or(x, div(x, 0x04))
            x := or(x, div(x, 0x10))
            x := or(x, div(x, 0x100))
            x := or(x, div(x, 0x10000))
            x := or(x, div(x, 0x100000000))
            x := or(x, div(x, 0x10000000000000000))
            x := or(x, div(x, 0x100000000000000000000000000000000))
            x := add(x, 1)
            let m := mload(0x40)
            mstore(m,           0xf8f9cbfae6cc78fbefe7cdc3a1793dfcf4f0e8bbd8cec470b6a28a7a5a3e1efd)
            mstore(add(m,0x20), 0xf5ecf1b3e9debc68e1d9cfabc5997135bfb7a7a3938b7b606b5b4b3f2f1f0ffe)
            mstore(add(m,0x40), 0xf6e4ed9ff2d6b458eadcdf97bd91692de2d4da8fd2d0ac50c6ae9a8272523616)
            mstore(add(m,0x60), 0xc8c0b887b0a8a4489c948c7f847c6125746c645c544c444038302820181008ff)
            mstore(add(m,0x80), 0xf7cae577eec2a03cf3bad76fb589591debb2dd67e0aa9834bea6925f6a4a2e0e)
            mstore(add(m,0xa0), 0xe39ed557db96902cd38ed14fad815115c786af479b7e83247363534337271707)
            mstore(add(m,0xc0), 0xc976c13bb96e881cb166a933a55e490d9d56952b8d4e801485467d2362422606)
            mstore(add(m,0xe0), 0x753a6d1b65325d0c552a4d1345224105391a310b29122104190a110309020100)
            mstore(0x40, add(m, 0x100))
            let magic := 0x818283848586878898a8b8c8d8e8f929395969799a9b9d9e9faaeb6bedeeff
            let shift := 0x100000000000000000000000000000000000000000000000000000000000000
            let a := div(mul(x, magic), shift)
            y := div(mload(add(m,sub(255,a))), shift)
            y := add(y, mul(256, gt(arg, 0x8000000000000000000000000000000000000000000000000000000000000000)))
        }
    }
}