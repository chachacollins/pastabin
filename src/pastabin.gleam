import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/option.{None}
import glisten.{Packet}
import gluid
import sqlight

type CmdState {
  AwaitingCommand
  Post(BytesTree)
  Get(BytesTree)
}

type AppState {
  AppState(db_conn: sqlight.Connection, comm: CmdState)
}

const port = 6969

const ip = "0.0.0.0"

type PastaBinError {
  UnknownCommand
  UnableToSavePost
}

fn awaiting_command_handler(
  state: AppState,
  msg: BitArray,
) -> Result(AppState, PastaBinError) {
  case msg {
    <<"POST\r\n":utf8>> -> Ok(AppState(..state, comm: Post(bytes_tree.new())))
    _ -> Error(UnknownCommand)
  }
}

//TODO: limit length of a single line
fn post_command_handler(
  state: AppState,
  prev_text: BytesTree,
  msg: BitArray,
  conn,
) -> Result(AppState, PastaBinError) {
  case msg {
    <<"DONE\r\n":utf8>> -> {
      let assert Ok(final_text) =
        bit_array.to_string(bytes_tree.to_bit_array(prev_text))
      let uuid = gluid.guidv4()
      let query =
        "insert into posts (id, data) values ("
        <> "'"
        <> uuid
        <> "'"
        <> ","
        <> "'"
        <> final_text
        <> "'"
        <> ");"
      case sqlight.exec(query, state.db_conn) {
        Ok(Nil) -> {
          let uuid = bit_array.from_string("post id: " <> uuid <> "\n")
          let assert Ok(_) = glisten.send(conn, bytes_tree.from_bit_array(uuid))
          Ok(AppState(..state, comm: AwaitingCommand))
        }
        Error(err) -> Error(UnableToSavePost)
      }
    }
    new_text -> {
      Ok(AppState(..state, comm: Post(bytes_tree.append(prev_text, new_text))))
    }
  }
}

fn pastabin(
  conn,
  state: AppState,
  msg: BitArray,
) -> Result(AppState, PastaBinError) {
  case state.comm {
    AwaitingCommand -> awaiting_command_handler(state, msg)
    Post(prev_text) -> post_command_handler(state, prev_text, msg, conn)
    Get(_) -> todo
  }
}

fn display_prompt(state: CmdState, conn) {
  let prompt = case state {
    AwaitingCommand -> bit_array.from_string("> ")
    Post(_) -> bit_array.from_string("post> ")
    Get(_) -> bit_array.from_string("get> ")
  }
  let assert Ok(_) = glisten.send(conn, bytes_tree.from_bit_array(prompt))
  Nil
}

fn initial(conn) {
  let assert Ok(db_conn) = sqlight.open("file:pastabindb")
  let state = AppState(db_conn: db_conn, comm: AwaitingCommand)
  display_prompt(state.comm, conn)
  #(state, None)
}

fn response(state: AppState, msg, conn) {
  let assert Packet(msg) = msg
  case pastabin(conn, state, msg) {
    Ok(state) -> {
      display_prompt(state.comm, conn)
      glisten.continue(state)
    }
    Error(err) ->
      case err {
        UnknownCommand -> {
          let assert Ok(cmd) = bit_array.to_string(msg)
          let err_msg = "ERROR: unknown command " <> cmd
          let assert Ok(_) = glisten.send(conn, bytes_tree.from_string(err_msg))
          display_prompt(state.comm, conn)
          glisten.continue(AppState(..state, comm: AwaitingCommand))
        }
        UnableToSavePost -> {
          let err_msg = "ERROR: unable to save post "
          let assert Ok(_) = glisten.send(conn, bytes_tree.from_string(err_msg))
          glisten.continue(AppState(..state, comm: AwaitingCommand))
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
