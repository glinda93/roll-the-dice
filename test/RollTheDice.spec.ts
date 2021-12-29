import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { expect } from "chai";
import { constants } from "ethers";
import { ethers } from "hardhat";
// eslint-disable-next-line node/no-missing-import
import { RollTheDice } from "../typechain";

// eslint-disable-next-line no-unused-vars
const GAME_STATE_BETTING = 1;
// eslint-disable-next-line no-unused-vars
const GAME_STATE_PLAYING = 2;
// eslint-disable-next-line no-unused-vars
const GAME_STATE_WAITING = 3;
const GAME_STATE_ENDED = 4;

describe("RollTheDice", () => {
  let contract: RollTheDice;
  let owner: SignerWithAddress;
  let users: SignerWithAddress[];
  const MOCK_SUBSCRIPTION_ID = 0;
  const MOCK_LINK = constants.AddressZero;

  async function deployContract(
    vrfCoordinatorContract:
      | "MockVRFCoordinator"
      | "MockVRFCoordinatorUnfulfillable" = "MockVRFCoordinator"
  ) {
    const contractFactory = await ethers.getContractFactory("RollTheDice");

    const vrfCoordFactory = await ethers.getContractFactory(
      vrfCoordinatorContract
    );
    const mockVrfCoordinator = await vrfCoordFactory.connect(owner).deploy();

    return await contractFactory
      .connect(owner)
      .deploy(mockVrfCoordinator.address, MOCK_LINK, MOCK_SUBSCRIPTION_ID);
  }

  async function createGame(
    caller: string | SignerWithAddress,
    targetScore: number,
    blind: number
  ) {
    const tx = await contract.connect(caller).createGame(targetScore, blind, {
      value: blind,
    });
    await tx.wait();
  }

  async function bet(player: SignerWithAddress, gameId: number, bet: number) {
    const txBet = await contract.connect(player).bet(gameId, {
      value: bet,
    });
    await txBet.wait();
  }

  async function getGameCounter() {
    return await contract.getGameCounter();
  }

  beforeEach(async () => {
    users = await ethers.getSigners();
    [owner] = users;
    contract = await deployContract();
  });

  describe("setMaxTargetScore", () => {
    const newMaxTargetScore = 50;

    it("should emit MaxTargetScoreChanged event", async () => {
      const oldMaxTargetScore = await contract.maxTargetScore();
      await expect(contract.connect(owner).setMaxTargetScore(newMaxTargetScore))
        .to.emit(contract, "MaxTargetScoreChanged")
        .withArgs(oldMaxTargetScore, newMaxTargetScore);
    });

    it("should update maxTargetScore when caller is admin", async () => {
      const tx = await contract
        .connect(owner)
        .setMaxTargetScore(newMaxTargetScore);
      await tx.wait();
      const maxTargetScore = await contract.maxTargetScore();
      expect(maxTargetScore).to.equal(newMaxTargetScore);
    });

    it("should revert when caller is not admin", async () => {
      const caller = users[1];
      await expect(
        contract.connect(caller).setMaxTargetScore(newMaxTargetScore)
      ).to.be.reverted;
    });
  });

  describe("createGame", () => {
    let caller: SignerWithAddress;

    beforeEach(() => {
      caller = users[1];
    });

    it("should create a game", async () => {
      await createGame(caller, 20, 5000);
      const gameCounter = await getGameCounter();
      expect(gameCounter).to.equal(1);
    });

    it("should emit GameCreated event", async () => {
      const targetScore = 20;
      const blind = 10000;
      expect(
        contract.connect(caller).createGame(targetScore, blind, {
          value: blind,
        })
      )
        .to.emit(contract, "GameCreated")
        .withArgs(0, targetScore, blind);
    });

    it("should revert when blind is zero", async () => {
      await expect(
        contract.connect(caller).createGame(20, 0)
      ).to.be.revertedWith("Blind should be greater than zero");
    });

    it("should revert when msg.value is smaller than blind", async () => {
      await expect(
        contract.connect(caller).createGame(20, 1000, {
          value: 999,
        })
      ).to.be.revertedWith(
        "msg.value should be equal to or greater than blind"
      );
    });

    it("should revert when game's targetScore is higher than contract targetScore", async () => {
      await expect(
        contract.connect(caller).createGame(21, 1000, {
          value: 1000,
        })
      ).to.be.revertedWith("Target score too high");
    });
  });

  describe("getGameCounter", async () => {
    it("should revert when caller is not admin", async () => {
      const caller = users[1];
      await expect(contract.connect(caller).getGameCounter()).to.be.reverted;
    });
  });

  describe("bet", async () => {
    let gameCreator: SignerWithAddress;
    let player: SignerWithAddress;
    const targetScore = 20;
    const blind = 1000;
    const gameId = 0;

    beforeEach(async () => {
      gameCreator = users[1];
      player = users[2];
      await createGame(gameCreator, targetScore, blind);
    });

    it("should emit a Bet event", async () => {
      await expect(
        contract.connect(player).bet(gameId, {
          value: blind,
        })
      )
        .to.emit(contract, "Bet")
        .withArgs(gameId, player.address, blind);
    });

    it("should revert when game is not created", async () => {
      await expect(
        contract.connect(player).bet(gameId + 1, {
          value: blind,
        })
      ).to.revertedWith("Game is not created");
    });

    it("should revert when already betted", async () => {
      await bet(player, gameId, blind);
      expect(
        contract.connect(player).bet(gameId, {
          value: blind,
        })
      ).to.revertedWith("Already betted");
    });

    it("should revert when msg.value is lower than blind", async () => {
      await expect(
        contract.connect(player).bet(gameId, {
          value: blind - 1,
        })
      ).to.be.revertedWith("Bet should be greater than blind");
    });
  });

  describe("predictAndRoll", () => {
    let gameCreator: SignerWithAddress;
    let player: SignerWithAddress;
    const targetScore = 20;
    const blind = 1000;
    const gameId = 0;
    let player1: SignerWithAddress;
    let player2: SignerWithAddress;

    beforeEach(async () => {
      gameCreator = users[1];
      player = users[2];
      player1 = gameCreator;
      player2 = player;
      await createGame(gameCreator, targetScore, blind);
    });

    context("when there is only one player", () => {
      it("should revert", async () => {
        await expect(
          contract.connect(gameCreator).predictAndRoll(gameId, 5)
        ).to.be.revertedWith("At least two players are required to play");
      });
    });

    context("when there are multiple players", () => {
      beforeEach(async () => {
        await bet(player, gameId, blind);
      });

      it("should emit Prediction event", async () => {
        await expect(contract.connect(player1).predictAndRoll(gameId, 5))
          .to.emit(contract, "Prediction")
          .withArgs(gameId, 0, player1.address, 5);
      });

      it("should emit Roll event", async () => {
        await expect(contract.connect(player1).predictAndRoll(gameId, 5))
          .to.emit(contract, "Roll")
          .withArgs(gameId, 0, 0);
      });

      it("should revert when it is not caller's turn", async () => {
        await expect(
          contract.connect(player2).predictAndRoll(gameId, 5)
        ).to.revertedWith("It's not your turn");
      });

      it("should revert when round is 0 and game state is not GAME_STATE_BETTING", async () => {
        contract = await deployContract("MockVRFCoordinatorUnfulfillable");
        await createGame(player1, targetScore, blind);
        await bet(player2, gameId, blind);

        await (
          await contract.connect(player1).predictAndRoll(gameId, 5)
        ).wait();
        await expect(
          contract.connect(player1).predictAndRoll(gameId, 6)
        ).to.be.revertedWith("Invalid game state");
      });

      it("should revert when prediction is not between 1 and 6", async () => {
        await expect(
          contract.connect(player1).predictAndRoll(gameId, 0)
        ).to.be.revertedWith("Prediction should be between 1 and 6");

        await expect(
          contract.connect(player1).predictAndRoll(gameId, 7)
        ).to.be.revertedWith("Prediction should be between 1 and 6");
      });
    });
  });

  context("when there are two players", () => {
    const targetScore = 5;
    const blind = 1000;
    const gameId = 0;
    let player1: SignerWithAddress;
    let player2: SignerWithAddress;

    beforeEach(async () => {
      [player1, player2] = users;
      await createGame(player1, targetScore, blind);
      await bet(player2, gameId, blind);
    });

    it("should change game state to GAME_STATE_ENDED when there is a winner", async () => {
      await contract.connect(player1).predictAndRoll(0, 1);
      await contract.connect(player1).predictAndRoll(0, 2);
      await contract.connect(player1).predictAndRoll(0, 3);
      const game = await contract.games(0);
      expect(game.state).to.be.equal(GAME_STATE_ENDED);
    });

    it("should switch turn when prediction is not correct", async () => {
      await contract.connect(player1).predictAndRoll(0, 2);
      let game = await contract.games(0);
      expect(game.turn).to.be.equal(1);
      expect(contract.connect(player1).predictAndRoll(0, 3)).to.be.revertedWith(
        "It's not your turn"
      );
      await contract.connect(player2).predictAndRoll(0, 5);
      game = await contract.games(0);
      expect(game.turn).to.be.equal(0);
    });
  });
});
