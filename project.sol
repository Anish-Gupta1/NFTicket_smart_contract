// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC1155} from "@openzeppelin/contracts@5.2.0/token/ERC1155/ERC1155.sol";
import {ERC1155Burnable} from "@openzeppelin/contracts@5.2.0/token/ERC1155/extensions/ERC1155Burnable.sol";
import {ERC1155Pausable} from "@openzeppelin/contracts@5.2.0/token/ERC1155/extensions/ERC1155Pausable.sol";
import {Ownable} from "@openzeppelin/contracts@5.2.0/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts@5.2.0/utils/Strings.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";


contract NFTicket is ERC1155, Ownable, ERC1155Pausable, ERC1155Burnable, ReentrancyGuard {
    using Strings for uint256;

    struct Organizer {
        string name;
        uint256 stakedAmount;
        uint256 totalMinted;   
        uint256 unsoldCount; 
        bool exist;
    }

    struct NFTInfo {
        address originalOwner;
        address currentOwner;
        uint256 lastSalePrice;
        uint8 resaleCount;
        uint256 batchNum;
    }

    struct BatchInfo {
        uint256 startTokenId;
        uint256 endTokenId;
    }
            
    // State Variables
    uint256 private nextTokenId = 1;
    uint256 private batchCounter = 1; // Start batch counter at 1
    string public postConcertURI;
    bool public metadataBurned;
    uint256 public constant MAX_TICKETS_PER_USER = 2;
    uint256 public constant MAX_RESALES = 2;
    uint256 public constant ROYALTY_PERCENT = 5;

    mapping(uint256 => NFTInfo) public nftInfo;
    mapping(uint256 => uint256) public nftPrices;
    mapping(address => Organizer) public organizers;
    mapping(address => uint256) public ticketsBought;
    mapping(uint256 => BatchInfo) public batchToTokenRange;

    // Events
    event MetadataBurned(string newURI);
    event OrganizerRegistered(address indexed organizer, string name);
    event KYCSuccess(address indexed user);
    event PriceSet(uint256 indexed tokenId, uint256 price);
    event BatchMinted(uint256 batchNumber, uint256 count, uint256 startTokenId, uint256 endTokenId);
    event BatchListed(uint256 indexed batchNum, uint256 price, uint256 startTokenId, uint256 endTokenId);

    constructor(string memory _initialURI, string memory _postConcertURI) 
        ERC1155(_initialURI)
        Ownable(msg.sender)
    {
        postConcertURI = _postConcertURI;
    }

    // Modifiers
    modifier onlyOrganizer() {
        require(organizers[msg.sender].exist, "Not organizer");
        _;
    }

    // Organizer Functions
    function registerOrganizer(string memory _name) external payable {
        require(msg.value >= 0.5 ether, "Minimum 0.5 ETH stake required");
        require(!organizers[msg.sender].exist, "Already registered");
        
        organizers[msg.sender] = Organizer(_name, msg.value, 0, 0, true);
        emit OrganizerRegistered(msg.sender, _name);
    }

    function withdrawStake() external onlyOrganizer nonReentrant {
        Organizer storage org = organizers[msg.sender];
        require(org.stakedAmount > 0, "No stake to withdraw");
        require(org.unsoldCount == 0, "Still has unsold NFTs");  // New check

        uint256 amount = org.stakedAmount;
        org.stakedAmount = 0;
        
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");
    }

    // Minting
    function mintBatch(uint256 count) external onlyOrganizer {
        require(count > 0, "Must mint at least one token");
        
        uint256[] memory ids = new uint256[](count);
        uint256[] memory amounts = new uint256[](count);

        Organizer storage org = organizers[msg.sender];
        org.totalMinted += count;
        org.unsoldCount += count;
        
        uint256 currentBatch = batchCounter; // Use the current batch number
        uint256 startTokenId = nextTokenId;
        uint256 endTokenId = nextTokenId + count - 1;
        
        // Store the batch token range
        batchToTokenRange[currentBatch] = BatchInfo({
            startTokenId: startTokenId,
            endTokenId: endTokenId
        });
        
        for (uint256 i = 0; i < count; i++) {
            ids[i] = nextTokenId;
            amounts[i] = 1;
            
            nftInfo[ids[i]] = NFTInfo({
                originalOwner: msg.sender,
                currentOwner: msg.sender,
                lastSalePrice: 0,
                resaleCount: 0,
                batchNum: currentBatch // Assign current batch number
            });
            
            nextTokenId++;
        }
        
        // Increment batch counter for the next batch
        batchCounter++;
        
        _mintBatch(msg.sender, ids, amounts, "");
        emit BatchMinted(currentBatch, count, startTokenId, endTokenId);
    }
    
    // NFT Trading
    function buyNFT(uint256 tokenId) external payable {
        require(ticketsBought[msg.sender] < MAX_TICKETS_PER_USER, "Ticket limit reached");
        require(nftPrices[tokenId] > 0, "NFT not for sale");
        require(msg.value == nftPrices[tokenId], "Incorrect ETH amount");

        address seller = ownerOf(tokenId);
        
        // Update resaleCount if not the original owner
        if (seller != nftInfo[tokenId].originalOwner) {
            nftInfo[tokenId].resaleCount += 1;
        }

        // Update state before transfers
        nftInfo[tokenId].lastSalePrice = msg.value;
        ticketsBought[msg.sender]++;
        nftPrices[tokenId] = 0;

        // Handle payments
        (bool success, ) = payable(seller).call{value: msg.value}("");
        require(success, "Payment failed");

        _safeTransferFrom(seller, msg.sender, tokenId, 1, "");
    }

    function listBatchForSale(uint256 batchNum, uint256 price) external onlyOrganizer {
        require(batchNum > 0 && batchNum < batchCounter, "Invalid batch number");
        
        BatchInfo memory batchInfo = batchToTokenRange[batchNum];
        uint256 startTokenId = batchInfo.startTokenId;
        uint256 endTokenId = batchInfo.endTokenId;
        
        // Iterate through all tokens in the batch
        for (uint256 tokenId = startTokenId; tokenId <= endTokenId; tokenId++) {
            // Check if the caller is the original owner of this token
            require(msg.sender == nftInfo[tokenId].originalOwner, "Not original owner of all tokens");
            require(balanceOf(msg.sender, tokenId) == 1, "Not owner of all tokens");
            require(nftInfo[tokenId].lastSalePrice == 0, "Some tokens already listed");
            
            // Set the price for this token
            nftPrices[tokenId] = price;
            
            // Emit event for this token
            emit PriceSet(tokenId, price);
        }
        
        // Emit a batch listing event
        emit BatchListed(batchNum, price, startTokenId, endTokenId);
    }

    // Keep the original function for listing individual NFTs
    function listForSale(uint256 tokenId, uint256 price) external {
        require(balanceOf(msg.sender, tokenId) == 1, "Not owner");
        require(msg.sender == nftInfo[tokenId].originalOwner, "Not original owner");
        require(nftInfo[tokenId].lastSalePrice == 0, "Already listed");
        
        nftPrices[tokenId] = price;
        emit PriceSet(tokenId, price);
    }

    function listForResale(uint256 tokenId, uint256 price) external {
        require(balanceOf(msg.sender, tokenId) == 1, "Not owner");
        require(nftInfo[tokenId].resaleCount < MAX_RESALES, "Max resales reached");
        require(nftInfo[tokenId].lastSalePrice > 0, "Use listForSale for initial listing");
        
        uint256 maxPrice = (nftInfo[tokenId].lastSalePrice * 110) / 100;
        require(price <= maxPrice, "Price exceeds 110% limit");

        nftPrices[tokenId] = price;
        emit PriceSet(tokenId, price);
    }

    // Metadata Burning
    function burnMetadata() external onlyOwner {
        require(!metadataBurned, "Already burned");
        metadataBurned = true;
        _setURI(postConcertURI);
        emit MetadataBurned(postConcertURI);
    }

    // View Functions
    function ownerOf(uint256 tokenId) public view returns (address) {
        require(nftInfo[tokenId].currentOwner != address(0), "Nonexistent token");
        return nftInfo[tokenId].currentOwner;
    }

    function uri(uint256 tokenId) public view override returns (string memory) {
        require(exists(tokenId), "Nonexistent token");
        
        uint256 batchNum = nftInfo[tokenId].batchNum;
        if (metadataBurned) {
            return string(abi.encodePacked(postConcertURI,batchNum.toString(), "/", tokenId.toString()));
        } else {
            // Use batch number in the URI format
            return string(abi.encodePacked(super.uri(tokenId), batchNum.toString(), "/", tokenId.toString()));
        }
    }

    // New function to get token ID range for a specific batch
    function getBatchTokenRange(uint256 batchNum) public view returns (uint256 startTokenId, uint256 endTokenId) {
        require(batchNum > 0 && batchNum < batchCounter, "Invalid batch number");
        
        BatchInfo memory info = batchToTokenRange[batchNum];
        return (info.startTokenId, info.endTokenId);
    }

    // New function to get all batch information
    function getAllBatchInfo() public view returns (uint256[] memory batchNumbers, uint256[] memory startTokenIds, uint256[] memory endTokenIds) {
        uint256 totalBatches = batchCounter - 1;
        
        batchNumbers = new uint256[](totalBatches);
        startTokenIds = new uint256[](totalBatches);
        endTokenIds = new uint256[](totalBatches);
        
        for (uint256 i = 1; i <= totalBatches; i++) {
            batchNumbers[i-1] = i;
            BatchInfo memory info = batchToTokenRange[i];
            startTokenIds[i-1] = info.startTokenId;
            endTokenIds[i-1] = info.endTokenId;
        }
        
        return (batchNumbers, startTokenIds, endTokenIds);
    }

    // Internal Overrides
    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override(ERC1155, ERC1155Pausable) {
        super._update(from, to, ids, values);

        for (uint256 i = 0; i < ids.length; i++) {
            uint256 tokenId = ids[i];
            address originalOwner = nftInfo[tokenId].originalOwner;

            // Update unsold count when transferring from original owner
            if (from == originalOwner) {
                Organizer storage org = organizers[from];
                org.unsoldCount -= values[i];
            }

            // Existing currentOwner updates
            if (from == address(0)) {
                // Minting: currentOwner already set
            } else if (to == address(0)) {
                nftInfo[tokenId].currentOwner = address(0);
            } else {
                nftInfo[tokenId].currentOwner = to;
            }
        }
    }

    function _ownerOf(uint256 tokenId) internal view returns (address) {
        return balanceOf(nftInfo[tokenId].originalOwner, tokenId) > 0 
            ? nftInfo[tokenId].originalOwner 
            : address(0);
    }

    function exists(uint256 tokenId) internal view returns (bool) {
        return nftInfo[tokenId].originalOwner != address(0);
    }
}