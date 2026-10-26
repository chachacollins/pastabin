import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/option.{None}
import glisten.{Packet}

type State {
  AwaitingCommand
  Post(BytesTree)
  Get(BytesTree)
}

const port = 6969

const ip = "0.0.0.0"

type PastaBinError {
  UnknownCommand
}

fn awaiting_command_handler(msg: BitArray) -> Result(State, PastaBinError) {
  case msg {
    <<"POST\r\n":utf8>> -> Ok(Post(bytes_tree.new()))
    _ -> Error(UnknownCommand)
  }
}

//TODO: limit length of a single line
fn post_command_handler(
  prev_text: BytesTree,
  msg: BitArray,
) -> Result(State, PastaBinError) {
  case msg {
    <<"DONE\r\n":utf8>> -> {
      io.println("--------------DONE-----------------")
      let assert Ok(final_text) =
        bit_array.to_string(bytes_tree.to_bit_array(prev_text))
      io.print(final_text)
      Ok(AwaitingCommand)
    }
    new_text -> {
      Ok(Post(bytes_tree.append(prev_text, new_text)))
    }
  }
}

fn pastabin(state: State, msg: BitArray) -> Result(State, PastaBinError) {
  case state {
    AwaitingCommand -> awaiting_command_handler(msg)
    Post(prev_text) -> post_command_handler(prev_text, msg)
    Get(_) -> todo
  }
}

fn display_prompt(conn) {
  let prompt = bit_array.from_string("> ")
  let assert Ok(_) = glisten.send(conn, bytes_tree.from_bit_array(prompt))
  Nil
}

fn initial(conn) {
  display_prompt(conn)
  #(AwaitingCommand, None)
}

fn response(state: State, msg, conn) {
  let assert Packet(msg) = msg
  case pastabin(state, msg) {
    Ok(state) -> {
      display_prompt(conn)
      glisten.continue(state)
    }
    Error(err) ->
      case err {
        UnknownCommand -> {
          let assert Ok(cmd) = bit_array.to_string(msg)
          let err_msg = "ERROR: unknown command " <> cmd
          let assert Ok(_) = glisten.send(conn, bytes_tree.from_string(err_msg))
          display_prompt(conn)
          glisten.continue(AwaitingCommand)
        }
      }
  }
}

pub fn main() -> Nil {
  let assert Ok(_) =
    glisten.new(initial, response)
    |> glisten.bind(ip)
    |> glisten.start(port)
  io.println("listening on addr: " <> ip <> " port: " <> int.to_string(port))
  process.sleep_forever()
}
