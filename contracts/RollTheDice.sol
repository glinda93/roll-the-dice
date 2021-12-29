//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Context.sol";

contract RollTheDice is Context, Ownable, AccessControl, VRFConsumerBaseV2 {
    uint8 public constant GAME_STATE_BETTING = 1;
    uint8 public constant GAME_STATE_PLAYING = 2;
    uint8 public constant GAME_STATE_WAITING = 3;
    uint8 public constant GAME_STATE_ENDED = 4;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    uint16 internal requestConfirmations = 3;
    // The gas lane to use, which specifies the maximum gas price to bump to.
    // For a list of available gas lanes on each network,
    // see https://docs.chain.link/docs/vrf-contracts/#configurations
    bytes32 internal keyHash =
        0xd89b2bf150e3b9e13446986e571fb9cab24b13cea0a43ea20a6049a85cc807cc;
    uint32 internal callbackGasLimit = 1000000;
    uint64 internal chainlinkSubscriptionId;

    uint256 public maxTargetScore = 20;
    uint256 public gameCounter;

    /**
     * @dev Struct for game data
     *
     * @custom:property {state} Can be one of {GAME_STATE_BETTING}, {GAME_STATE_PLAYING}, {GAME_STATE_ENDED}
     * @custom:property {targetScore} First player scores equal to or higher than this point will claim the {pot}
     * @custom:property {turn} Index of player who is in turn
     * @custom:property {round} Total count of dice rolling
     * @custom:property {pot} Total sum of {blind}s
     * @custom:property {blind} Players are required to bet this amount to play the game
     * @custom:property {players} Addresses of players
     * @custom:property {bets} Mapping of player address to bet amount
     * @custom:property {predictions} Mapping of {round} to dice point prediction
     * @custom:property {scores} Mapping of player address to score
     * @custom:property {points} Mapping of {round} to dice output
     */
    struct Game {
        uint8 state;
        uint8 targetScore;
        uint8 turn;
        uint8 round;
        uint256 pot;
        uint256 blind;
        address[] players;
        mapping(address => uint256) bets;
        mapping(uint8 => uint8) predictions;
        mapping(address => uint8) scores;
        mapping(uint8 => uint8) points;
    }

    /**
     * @dev Mapping of game ID to {Game}
     */
    mapping(uint256 => Game) public games;

    /**
     * @dev Mapping of Chainlink request Id to game ID
     */
    mapping(uint256 => uint256) public requests;

    VRFCoordinatorV2Interface internal COORDINATOR;
    LinkTokenInterface internal LINKTOKEN;

    event MaxTargetScoreChanged(uint256 oldScore, uint256 newScore);
    event GameCreated(uint256 gameCounter, uint8 targetScore, uint256 blind);
    event Bet(uint256 gameCounter, address better, uint256 bet);
    event Prediction(
        uint256 gameCounter,
        uint8 round,
        address player,
        uint8 prediction
    );
    event Roll(uint256 gameCounter, uint8 round, uint256 requestId);

    constructor(
        address vrfCoordinator,
        address link,
        uint64 _chainlinkSubscriptionId
    ) VRFConsumerBaseV2(vrfCoordinator) {
        _grantRole(ADMIN_ROLE, _msgSender());

        chainlinkSubscriptionId = _chainlinkSubscriptionId;
        COORDINATOR = VRFCoordinatorV2Interface(vrfCoordinator);
        LINKTOKEN = LinkTokenInterface(link);
    }

    /**
     * @dev Sets max target score of games
     *
     * Requirements:
     * - the caller must have {ADMIN_ROLE}
     */
    function setMaxTargetScore(uint256 _maxTargetScore)
        external
        onlyRole(ADMIN_ROLE)
    {
        uint256 oldScore = maxTargetScore;
        maxTargetScore = _maxTargetScore;
        emit MaxTargetScoreChanged(oldScore, maxTargetScore);
    }

    /**
     * @dev Returns total game counts
     *
     * Requirements:
     * - the caller must have {ADMIN_ROLE}
     */
    function getGameCounter()
        external
        view
        onlyRole(ADMIN_ROLE)
        returns (uint256)
    {
        return gameCounter;
    }

    /**
     * @dev Creates a game, emits a {GameCreated} event and increase {gameCounter}
     */
    function createGame(uint8 targetScore, uint256 blind) public payable {
        require(blind > 0, "Blind should be greater than zero");
        require(
            msg.value >= blind,
            "msg.value should be equal to or greater than blind"
        );
        require(targetScore <= maxTargetScore, "Target score too high");

        _createGame(targetScore, blind);

        emit GameCreated(gameCounter, targetScore, blind);
        gameCounter = gameCounter + 1;
    }

    /**
     * @dev Bets on a game and emits a {Bet} event
     */
    function bet(uint256 gameId) public payable {
        require(games[gameId].blind > 0, "Game is not created");
        require(
            msg.value >= games[gameId].blind,
            "Bet should be greater than blind"
        );
        require(games[gameId].bets[_msgSender()] == 0, "Already betted");
        require(
            games[gameId].state == GAME_STATE_BETTING,
            "Betting has already ended"
        );
        require(
            games[gameId].players.length < 255,
            "Cannot have more than 255 players"
        );

        _bet(gameId, _msgSender());

        emit Bet(gameId, _msgSender(), games[gameId].blind);
    }

    /**
     * @dev User in turn predicts output and rolls the dice
     *
     * Requires:
     * - {msg.sender} should be in turn
     * - {state} should be {GAME_STATE_BETTING}, if {round} is zero; otherwise {state} should be {GAME_STATE_PLAYING}
     */
    function predictAndRoll(uint256 gameId, uint8 prediction) external {
        address[] memory players = games[gameId].players;
        uint8 turn = games[gameId].turn;
        uint8 round = games[gameId].round;
        uint8 state = games[gameId].state;

        require(players[turn] == _msgSender(), "It's not your turn");
        if (round == 0) {
            require(
                players.length > 1,
                "At least two players are required to play"
            );
            require(state == GAME_STATE_BETTING, "Invalid game state");
        } else {
            require(state == GAME_STATE_PLAYING, "Invalid game state");
        }
        require(
            prediction >= 1 && prediction <= 6,
            "Prediction should be between 1 and 6"
        );

        _predict(gameId, prediction);

        games[gameId].state = GAME_STATE_PLAYING;

        emit Prediction(gameId, round, _msgSender(), prediction);

        games[gameId].state = GAME_STATE_WAITING;

        uint256 requestId = _roll(gameId);

        emit Roll(gameId, round, requestId);
    }

    /**
     * @dev Fulfill VRF response
     *
     * Requires:
     * - Game state should be {GAME_STATE_WAITING}
     */
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords)
        internal
        override
    {
        uint256 gameId = requests[requestId];
        uint8 face = _convertRandomWordsToFace(randomWords);
        require(
            games[gameId].state == GAME_STATE_WAITING,
            "Invalid game state"
        );
        _handleOutput(gameId, face);
    }

    /**
     * @dev Creates a game
     *
     * Internal function without parameter validations
     */
    function _createGame(uint8 targetScore, uint256 blind) internal {
        games[gameCounter].state = GAME_STATE_BETTING;
        games[gameCounter].targetScore = targetScore;
        games[gameCounter].blind = blind;
        games[gameCounter].players.push(_msgSender());
        games[gameCounter].bets[_msgSender()] = blind;
        games[gameCounter].pot += blind;
    }

    /**
     * @dev Bets on a game
     *
     * Internal function without parameter validations
     */
    function _bet(uint256 gameId, address better) internal {
        uint256 blind = games[gameId].blind;
        games[gameId].bets[better] = blind;
        games[gameId].pot += blind;
        games[gameId].players.push(better);
    }

    /**
     * @dev Save user's prediction
     *
     * Internal function without parameter validations
     */
    function _predict(uint256 gameId, uint8 prediction) internal {
        games[gameId].predictions[games[gameId].round] = prediction;
    }

    /**
     * @dev Send a random word requests to Chainlink and save it to {requests}
     */
    function _roll(uint256 gameId) internal returns (uint256) {
        uint256 requestId = COORDINATOR.requestRandomWords(
            keyHash,
            chainlinkSubscriptionId,
            requestConfirmations,
            callbackGasLimit,
            1
        );

        requests[requestId] = gameId;

        return requestId;
    }

    /**
     * @dev Gets dice point from uint256
     */
    function _convertRandomWordsToFace(uint256[] memory randomWords)
        internal
        pure
        returns (uint8)
    {
        return uint8(randomWords[0] % 6) + 1;
    }

    /**
     * @dev Adds a player score
     *
     * Internal function without parameter validations
     */
    function _addScore(
        uint256 gameId,
        address player,
        uint8 score
    ) internal returns (uint8) {
        games[gameId].scores[player] += score;

        return games[gameId].scores[player];
    }

    /**
     * @dev Handles dice output result
     *
     * Internal function without parameter validations
     */
    function _handleOutput(uint256 gameId, uint8 face) internal {
        uint8 turn = games[gameId].turn;
        uint8 nextTurn = turn;
        uint8 round = games[gameId].round;
        address playerInTurn = games[gameId].players[turn];
        uint8 prediction = games[gameId].predictions[round];

        if (face == prediction) {
            uint8 score = _addScore(gameId, playerInTurn, face);

            if (score >= games[gameId].targetScore) {
                return _endGame(gameId, playerInTurn);
            }
        } else {
            nextTurn = _getNextTurn(
                turn,
                uint8(games[gameId].players.length - 1)
            );
        }

        _nextRound(gameId, nextTurn);
    }

    /**
     * @dev Ends a game and sends pot to the {winner}
     *
     * Internal function without parameter validations
     */
    function _endGame(uint256 gameId, address winner) internal {
        games[gameId].state = GAME_STATE_ENDED;
        _transfer(payable(winner), games[gameId].pot);
    }

    /**
     * @dev Transfers {amount} of Ethers to user
     *
     * Internal function, should never be called directly
     */
    function _transfer(address payable to, uint256 amount) internal {
        (bool sent, bytes memory data) = to.call{value: amount}("");
        require(sent, "Failed to send Ether");
    }

    function _getNextTurn(uint8 turn, uint8 maxTurn)
        internal
        pure
        returns (uint8)
    {
        unchecked {
            uint8 nextTurn = turn + 1;
            if (nextTurn > maxTurn) {
                return 0;
            }

            return nextTurn;
        }
    }

    function _nextRound(uint256 gameId, uint8 turn) internal {
        games[gameId].turn = turn;
        games[gameId].round += 1;
        games[gameId].state = GAME_STATE_PLAYING;
    }
}
