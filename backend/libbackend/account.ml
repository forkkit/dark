open Core_kernel
open Libexecution
open Types
module Hash = Sodium.Password_hash.Bytes

let banned_usernames : string list =
  (* originally from https://ldpreload.com/blog/names-to-reserve *)
  (* we allow www, because we have a canvas there *)
  [ "abuse"
  ; "admin"
  ; "administrator"
  ; "autoconfig"
  ; "broadcasthost"
  ; "ftp"
  ; "hostmaster"
  ; "imap"
  ; "info"
  ; "is"
  ; "isatap"
  ; "it"
  ; "localdomain"
  ; "localhost"
  ; "mail"
  ; "mailer-daemon"
  ; "marketing"
  ; "mis"
  ; "news"
  ; "nobody"
  ; "noc"
  ; "noreply"
  ; "no-reply"
  ; "pop"
  ; "pop3"
  ; "postmaster"
  ; "root"
  ; "sales"
  ; "security"
  ; "smtp"
  ; "ssladmin"
  ; "ssladministrator"
  ; "sslwebmaster"
  ; "support"
  ; "sysadmin"
  ; "usenet"
  ; "uucp"
  ; "webmaster"
  ; "wpad" ]
  @ (* original to us *)
    (* alpha, but not beta, because user beta already exists (with ownership
     * transferred to us *)
  ["billing"; "dev"; "alpha"]


type username = string [@@deriving yojson]

type account =
  { username : username
  ; password : Password.t
  ; email : string
  ; name : string }

type uuidmt = Uuidm.t

let uuidmt_to_yojson (uuid : uuidmt) : Yojson.Safe.t =
  `String (Uuidm.to_string uuid)


type user_info =
  { username : username
  ; email : string
  ; name : string
  ; admin : bool
  ; id : uuidmt }
[@@deriving to_yojson]

type user_info_and_created_at =
  { username : username
  ; email : string
  ; name : string
  ; admin : bool
  ; id : uuidmt
  ; created_at : string }
[@@deriving to_yojson]

(************************)
(* Adding *)
(************************)
let validate_username (username : string) : (unit, string) Result.t =
  (* rules: no uppercase, ascii only, must start with letter, other letters can
   * be numbers or underscores. 3-20 characters. *)
  let regex = Re2.create_exn "^[a-z][a-z0-9_]{2,20}$" in
  if Re2.matches regex username
  then Ok ()
  else
    Error
      ( "Invalid username '"
      ^ username
      ^ "', must match /^[a-z][a-z0-9_]{2,20}$/" )


let validate_email (email : string) : (unit, string) Result.t =
  (* just checking it's roughly the shape of an email *)
  let regex = Re2.create_exn ".+@.+\\..+" in
  if Re2.matches regex email
  then Ok ()
  else Error ("Invalid email '" ^ email ^ "'")


let validate_account (account : account) : (unit, string) Result.t =
  validate_username account.username
  |> Prelude.Result.and_ (validate_email account.email)


let insert_account
    ?(validate : bool = true)
    ~(analytics_metadata : Types.RuntimeT.dval_map option)
    (account : account) : (unit, string) Result.t =
  let result = if validate then validate_account account else Ok () in
  let analytics_metadata =
    analytics_metadata
    |> Option.value ~default:([] |> Types.RuntimeT.DvalMap.from_list)
  in
  Result.map result ~f:(fun () ->
      Db.run
        ~name:"insert_account"
        ~subject:account.username
        "INSERT INTO accounts
    (id, username, name, email, admin, password, segment_metadata)
    VALUES
    ($1, $2, $3, $4, false, $5, $6::jsonb)
    ON CONFLICT DO NOTHING"
        ~params:
          [ Uuid (Util.create_uuid ())
          ; String account.username
          ; String account.name
          ; String account.email
          ; String (Password.to_bytes account.password)
          ; QueryableDvalmap analytics_metadata ])
  |> Result.bind ~f:(fun () ->
         if Db.exists
              ~name:"check_inserted_account"
              ~subject:account.username
              "SELECT 1 from ACCOUNTS where
               username = $1 AND name = $2 AND email = $3 AND password = $4"
              ~params:
                [ String account.username
                ; String account.name
                ; String account.email
                ; String (Password.to_bytes account.password) ]
         then Ok ()
         else
           Error
             "Insert failed, probably because the username is already taken.")


(* Passwords set here are only valid locally, production uses auth0 to check
 * access *)
let upsert_account ?(validate : bool = true) (account : account) :
    (unit, string) Result.t =
  let result = if validate then validate_account account else Ok () in
  Result.map result ~f:(fun () ->
      Db.run
        ~name:"upsert_account"
        ~subject:account.username
        "INSERT INTO accounts
    (id, username, name, email, admin, password)
    VALUES
    ($1, $2, $3, $4, false, $5)
    ON CONFLICT (username)
    DO UPDATE SET name = EXCLUDED.name,
                  email = EXCLUDED.email,
                  password = EXCLUDED.password"
        ~params:
          [ Uuid (Util.create_uuid ())
          ; String account.username
          ; String account.name
          ; String account.email
          ; String (Password.to_bytes account.password) ])


let upsert_account_exn ?(validate : bool = true) (account : account) : unit =
  upsert_account ~validate account
  |> Prelude.Result.ok_or_internal_exception "Cannot upsert account"


(* Passwords set here are only valid locally, production uses auth0 to check
 * access *)
let upsert_admin ?(validate : bool = true) (account : account) :
    (unit, string) Result.t =
  Result.map (validate_account account) ~f:(fun () ->
      Db.run
        ~name:"upsert_admin"
        ~subject:account.username
        "INSERT INTO accounts as u
    (id, username, name, email, admin, password)
    VALUES
    ($1, $2, $3, $4, true, $5)
    ON CONFLICT (username)
    DO UPDATE SET name = EXCLUDED.name,
                  email = EXCLUDED.email,
                  admin = true,
                  password = EXCLUDED.password"
        ~params:
          [ Uuid (Util.create_uuid ())
          ; String account.username
          ; String account.name
          ; String account.email
          ; String (Password.to_bytes account.password) ])


let upsert_admin_exn ?(validate : bool = true) (account : account) : unit =
  upsert_admin ~validate account
  |> Prelude.Result.ok_or_internal_exception "Cannot upsert account"


(************************)
(* Querying *)
(************************)
let username_of_id id =
  Db.fetch_one_option
    ~name:"account_of_id"
    ~subject:(Uuidm.to_string id)
    "SELECT username from accounts
     WHERE accounts.id = $1"
    ~params:[Uuid id]
  |> Option.map ~f:List.hd_exn


let id_of_username username : Uuidm.t option =
  Db.fetch_one_option
    ~name:"account_of_username"
    ~subject:username
    "SELECT id from accounts
     WHERE accounts.username = $1"
    ~params:[String username]
  |> Option.map ~f:List.hd_exn
  |> fun x -> match x with Some sid -> Uuidm.of_string sid | None -> None


let get_user username =
  Db.fetch_one_option
    ~name:"get_user"
    ~subject:username
    "SELECT name, email, admin, id from accounts
     WHERE accounts.username = $1"
    ~params:[String username]
  |> Option.bind ~f:(function
         | [name; email; admin; id] ->
             Some
               { username
               ; name
               ; admin = admin = "t"
               ; email
               ; id = id |> Uuidm.of_string |> Option.value_exn }
         | _ ->
             None)


let get_user_created_at_exn username =
  Db.fetch_one
    ~name:"get_user_and_created_at"
    ~subject:username
    "SELECT created_at from accounts
     WHERE accounts.username = $1"
    ~params:[String username]
  |> List.hd_exn
  |> Db.date_of_sqlstring


let get_user_and_created_at_and_analytics_metadata username =
  Db.fetch_one_option
    ~name:"get_user_and_created_at"
    ~subject:username
    "SELECT name, email, admin, created_at, id, segment_metadata from accounts
     WHERE accounts.username = $1"
    ~params:[String username]
  |> Option.bind ~f:(function
         | [name; email; admin; created_at; id; analytics_metadata] ->
             Some
               ( { username
                 ; name
                 ; admin = admin = "t"
                 ; email
                 ; id = id |> Uuidm.of_string |> Option.value_exn
                 ; created_at =
                     created_at
                     |> Db.date_of_sqlstring
                     |> Core.Time.to_string_iso8601_basic
                          ~zone:Core.Time.Zone.utc }
               , analytics_metadata
                 |> fun s ->
                 (* If it's NULL,then we'll get an empty string, don't bother
                  * trying to parse *)
                 if s = "" then `Assoc [] else Yojson.Safe.from_string s )
         | _ ->
             None)


let get_user_by_email email =
  Db.fetch_one_option
    ~name:"get_user_by_email"
    ~subject:email
    "SELECT name, username, admin, id from accounts
     WHERE accounts.email = $1"
    ~params:[String email]
  |> Option.bind ~f:(function
         | [name; username; admin; id] ->
             Some
               { username
               ; name
               ; admin = admin = "t"
               ; email
               ; id = id |> Uuidm.of_string |> Option.value_exn }
         | _ ->
             None)


let get_users () =
  Db.fetch ~name:"get_users" "SELECT username from accounts" ~params:[]
  |> List.map ~f:List.hd_exn


let is_admin ~username : bool =
  Db.exists
    ~subject:username
    ~name:"is_admin"
    "SELECT 1 from accounts
     WHERE accounts.username = $1
       AND accounts.admin = true"
    ~params:[String username]


(* Any external calls to this should also call Stroller.heapio_identify_user;
 * we can't do it here because that sets up a module dependency cycle *)
let set_admin ~username (admin : bool) : unit =
  Db.run
    ~name:"set_admin"
    ~subject:username
    "UPDATE accounts SET admin = $1 where username = $2"
    ~params:[Bool admin; String username]


(* Returns None if no valid user, or Some username _from the db_ if valid. Note:
 * the input username may also be an email address. We do this because users
 * input data this way and it seems silly not to allow it.
 *
 * No need to detect which and SQL differently; no valid username contains a
 * '@', and every valid email address does. [If you say 'uucp bang path', I will
 * laugh and then tell you to give me a real email address.] *)
let authenticate ~(username_or_email : username) ~(password : string) :
    string option =
  match
    Db.fetch_one_option
      ~name:"valid_user"
      ~subject:username_or_email
      "SELECT username, password from accounts
           WHERE accounts.username = $1 OR accounts.email = $1"
      ~params:[String username_or_email]
  with
  | Some [db_username; db_password] ->
      if password
         |> Bytes.of_string
         |> Hash.wipe_to_password
         |> Hash.verify_password_hash (Bytes.of_string (B64.decode db_password))
      then Some db_username
      else None
  | None | _ ->
      None


let can_access_operations ~(username : username) : bool = is_admin ~username

let owner ~(auth_domain : string) : Uuidm.t option =
  let auth_domain = String.lowercase auth_domain in
  if List.mem banned_usernames auth_domain ~equal:( = )
  then None
  else
    Db.fetch_one_option
      ~name:"owner"
      ~subject:auth_domain
      "SELECT id from accounts
     WHERE accounts.username = $1"
      ~params:[String auth_domain]
    |> Option.map ~f:List.hd_exn
    |> Option.bind ~f:Uuidm.of_string


let auth_domain_for host : string =
  match String.split host '-' with d :: _ -> d | _ -> host


let for_host (host : string) : Uuidm.t option = host |> auth_domain_for |> owner

let for_host_exn (host : string) : Uuidm.t =
  host
  |> for_host
  |> fun o -> Option.value_exn ~message:("No owner found for host " ^ host) o


(************************)
(* Darkinternal functions *)
(************************)

(* Any external calls to this should also call Stroller.heapio_identify_user;
 * we can't do it here because that sets up a module dependency cycle *)
let insert_user
    ~(username : string)
    ~(email : string)
    ~(name : string)
    ?(analytics_metadata : Types.RuntimeT.dval_map option)
    () : (unit, string) Result.t =
  (* As of the move to auth0, we  no longer store passwords in postgres. We do
   * still use postgres locally, which is why we're not removing the field
   * entirely. Local account creation is done in
   * upsert_account_exn/upsert_admin_exn, so using Password.invalid here does
   * not affect that *)
  let password = Password.invalid in
  insert_account {username; email; name; password} ~analytics_metadata


(* Any external calls to this should also call Stroller.heapio_identify_user;
 * we can't do it here because that sets up a module dependency cycle *)
let upsert_user ~(username : string) ~(email : string) ~(name : string) () :
    (unit, string) Result.t =
  let password = Password.invalid in
  upsert_account {username; email; name; password}


let init_testing () : unit =
  upsert_account_exn
    { username = "test_unhashed"
    ; password = Password.from_hash "fVm2CUePzGKCwoEQQdNJktUQ"
    ; email = "test+unhashed@darklang.com"
    ; name = "Dark OCaml Tests with Unhashed Password" } ;
  upsert_account_exn
    { username = "test"
    ; password = Password.from_plaintext "fVm2CUePzGKCwoEQQdNJktUQ"
    ; email = "test@darklang.com"
    ; name = "Dark OCaml Tests" } ;
  upsert_admin_exn
    { username = "test_admin"
    ; password = Password.from_plaintext "fVm2CUePzGKCwoEQQdNJktUQ"
    ; email = "test+admin@darklang.com"
    ; name = "Dark OCaml Test Admin" } ;
  ()


let upsert_admins () : unit =
  upsert_admin_exn
    { username = "dark"
    ; password =
        Password.from_hash
          "JGFyZ29uMmkkdj0xOSRtPTMyNzY4LHQ9NCxwPTEkcEQxWXBLOG1aVStnUUJUYXdKZytkQSR3TWFXb1hHOER1UzVGd2NDYzRXQVc3RlZGN0VYdVpnMndvZEJ0QnY1bkdJAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    ; email = "ops+darkuser@darklang.com"
    ; name = "Kiera Dubh" } ;
  upsert_admin_exn
    { username = "paul"
    ; password =
        Password.from_hash
          "JGFyZ29uMmkkdj0xOSRtPTMyNzY4LHQ9NCxwPTEkcEQxWXBLOG1aVStnUUJUYXdKZytkQSR3TWFXb1hHOER1UzVGd2NDYzRXQVc3RlZGN0VYdVpnMndvZEJ0QnY1bkdJAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    ; email = "paul@darklang.com"
    ; name = "Paul Biggar" } ;
  ()


(* accounts to create namespaces for dark canvases *)
let upsert_useful_canvases () : unit =
  (* Needed for tests *)
  upsert_account_exn
    ~validate:false
    { username = "sample"
    ; password = Password.invalid
    ; email = "ops+sample@darklang.com"
    ; name = "Sample Owner" }


let upsert_banned_accounts () : unit =
  ignore
    ( banned_usernames
    |> List.map ~f:(fun username ->
           upsert_account_exn
             ~validate:false
             { username
             ; password = Password.invalid
             ; email = "ops+" ^ username ^ "@darklang.com"
             ; name = "Disallowed account" }) ) ;
  ()


let init () : unit =
  if Config.create_accounts
  then (
    init_testing () ;
    upsert_banned_accounts () ;
    upsert_admins () ;
    upsert_useful_canvases () ;
    () )


module Testing = struct
  let validate_username = validate_username

  let validate_email = validate_email
end
