pragma solidity ^0.5.0;

import "./SafeMath.sol";
import "./Ownable.sol";
import "./Stoppable.sol";

contract RockPaperScissors is Stoppable {

    using SafeMath for uint;

    mapping (address => uint) public balances;
    mapping (bytes32 => Game) public games; // hash(p1 address, p1 pw, p1 move, contract address) => Game

    enum Move { NIL, ROCK, PAPER, SCISSORS } // <----- For reference, { 0, 1, 2, 3 }
    enum Winner { NIL, P1, P2, DRAW }

    event LogNewGame(
        address indexed p1,
        address indexed p2,
        bytes32 indexed p1HashedMove,
        uint wager,
        uint moveDeadline,
        uint confirmDuration
    );
    event LogP2Move(
        address indexed p2,
        bytes32 indexed p1HashedMove,
        Move p2Move,
        uint confirmDeadline
    );
    event LogGameConfirmed(
        address indexed p1,
        address indexed p2,
        bytes32 indexed p1HashedMove,
        Winner winner,
        uint wager
    );
    event LogBalanceWithdrawn(
        address indexed dst,
        uint amount
    );

    struct Game {
        address p1;
        address p2;
        Move p2Move;
        uint wager;
        uint deadline;
        uint confirmDuration;
    }

    constructor(bool initialRunState) public Stoppable(initialRunState) {}

    function stringToBytes32Hash(string memory seed) public pure returns(bytes32) {
        return keccak256(abi.encode(seed));
    }

    function hashMove(address p1, bytes32 password, Move move)
    public view returns(bytes32 hashedMove) {
        require(move != Move.NIL, "E_IM");
        return keccak256(abi.encodePacked(p1, password, move, address(this)));
    }

    function newGame(bytes32 hashedMove, address p2, uint wager, uint moveDuration, uint confirmDuration)
    public payable onlyIfRunning addressNonZero(msg.sender) addressNonZero(p2) returns(bool success) {
        require((moveDuration > 0) && (confirmDuration > 0), "E_BD");
        uint moveDeadline = block.number.add(moveDuration);
        require(games[hashedMove].p1 == address(0), "E_GE");
        games[hashedMove].p1 = msg.sender;
        games[hashedMove].p2 = p2;
        games[hashedMove].wager = wager;
        games[hashedMove].deadline = moveDeadline;
        games[hashedMove].confirmDuration = confirmDuration;
        addWager(wager, msg.value);
        emit LogNewGame(msg.sender, p2, hashedMove, wager, moveDeadline, confirmDuration);
        return true;
    }

    function p2Move(bytes32 p1HashedMove, Move _p2Move)
    public payable onlyIfRunning returns(bool success) {
        require(_p2Move != Move.NIL, "E_IM");
        Game storage g = games[p1HashedMove];
        require(g.p2Move == Move.NIL, "E_AM");
        require(msg.sender == g.p2, "E_UA");
        g.p2Move = _p2Move;
        uint confirmDeadline = block.number.add(g.confirmDuration);
        g.deadline = confirmDeadline;
        g.confirmDuration = 0;
        addWager(g.wager, msg.value);
        emit LogP2Move(msg.sender, p1HashedMove, _p2Move, confirmDeadline);
        return true;
    }

    function addWager(uint wager, uint msgValue)
    internal {
        if (wager > msgValue) {
            uint diff = wager.sub(msgValue);
            balances[msg.sender] = balances[msg.sender].sub(diff);
        } else if (wager < msgValue) {
            uint diff = msgValue.sub(wager);
            balances[msg.sender] = balances[msg.sender].add(diff);
        } else {
            return;
        }
    }

    // Anyone can confirm the game given the right password and move.
    // No point restricting the caller to player 1...
    function confirmGame(address p1, bytes32 p1Password, Move p1Move)
    public onlyIfRunning returns(bool success) {
        bytes32 p1HashedMove = hashMove(p1, p1Password, p1Move);
        Game storage g = games[p1HashedMove];
        Move _p2Move = g.p2Move;
        uint wager = g.wager;
        address p2 = g.p2;
        Winner winner;
        if (_p2Move != Move.NIL) {
            winner = getGameResult(p1Move, _p2Move);
            if (winner == Winner.P1) {
                balances[p1] = balances[p1].add(wager.mul(2));
            } else if (winner == Winner.P2) {
                balances[p2] = balances[p2].add(wager.mul(2));
            } else if (winner == Winner.DRAW) {
                balances[p1] = balances[p1].add(wager);
                balances[p2] = balances[p2].add(wager);
            } else {
                revert("E_NIL");
            }
            g.p2Move = Move.NIL;
        } else if (g.deadline < block.number) {
            winner = Winner.P1;
            balances[p1] = balances[p1].add(wager.mul(2));
            g.confirmDuration = 0;
        } else {
            revert("E_UG");
        }
        emit LogGameConfirmed(p1, p2, p1HashedMove, winner, wager);
        requiredCleanUp(g);
        return true;
    }

    // If player 1 is unresponsive, player 2 can still get the wager.
    // Can be called by anyone.
    function claimUnconfirmedGame(bytes32 p1HashedMove)
    public onlyIfRunning returns(bool success) {
        Game storage g = games[p1HashedMove];
        address p2 = g.p2;
        Move _p2Move = g.p2Move;
        require(p2 != address(0), "E_BG");
        require(_p2Move != Move.NIL, "E_UG");
        require(g.deadline < block.number, "E_UC");
        uint wager = g.wager;
        balances[p2] = balances[p2].add(wager.mul(2));
        emit LogGameConfirmed(g.p1, p2, p1HashedMove, Winner.P2, wager);
        requiredCleanUp(g);
        g.p2Move = Move.NIL;
        g.confirmDuration = 0;
        return true;
    }

    function getGameResult(Move _p1Move, Move _p2Move)
    public pure returns(Winner) {
        if (_p2Move == Move.NIL) return Winner.P1;
        if (_p1Move == _p2Move) return Winner.DRAW;
        if ((uint(_p2Move) - uint(_p1Move) == 1) || (uint(_p1Move) - uint(_p2Move) == 2)) return Winner.P2;
        if ((uint(_p1Move) - uint(_p2Move) == 1) || (uint(_p2Move) - uint(_p1Move) == 2)) return Winner.P1;
    }

    function withdraw()
    public returns(bool success) {
        uint amount = balances[msg.sender];
        require(amount > 0, "E_IB");
        balances[msg.sender] = 0;
        emit LogBalanceWithdrawn(msg.sender, amount);
        msg.sender.transfer(amount);
        return true;
    }

    function requiredCleanUp(Game storage g)
    internal {
        g.p2 = address(0);
        g.wager = 0;
        g.deadline = 0;
    }
}