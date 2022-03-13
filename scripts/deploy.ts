import hre, { ethers } from "hardhat";

declare global {
  // eslint-disable-next-line no-unused-vars
  namespace NodeJS {
    export interface ProcessEnv {
      VRF_COORDINATOR: string;
      LINK_TOKEN: string;
      SUBSCRIPTION_ID: string;
      FUND_LINK_AMOUNT: string;
    }
  }
}

async function main() {
  const tokenFactory = await ethers.getContractFactory("RollTheDice");
  const token = await tokenFactory.deploy(
    process.env.VRF_COORDINATOR,
    process.env.LINK_TOKEN,
    process.env.SUBSCRIPTION_ID
  );
  console.log(`RollTheDice has been deployed to ${token.address}`);
  const fundAmount = process.env.FUND_LINK_AMOUNT;
  if (fundAmount) {
    await hre.fundLink(hre, token.address, fundAmount, process.env.LINK_TOKEN);
    console.log(`${fundAmount} LINK has been funded`);
  } else {
    console.warn("FUND_LINK_AMOUNT is not provided. Skipped fund link");
  }
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
