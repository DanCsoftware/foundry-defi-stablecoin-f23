const { ethers } = require("ethers");

// Define the error signature you want to calculate the selector for
const errorSignature = "DecentralizedStableCoin__BurnAmountExceedsBalance()";

// Calculate the Keccak-256 hash of the error signature
const errorSelector = ethers.utils.id(errorSignature).substring(0, 10);

// Output the result
console.log("Error Selector:", errorSelector);
