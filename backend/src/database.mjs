import {DatabaseSync} from 'node:sqlite';
export class AuthorityError extends Error {constructor(code,status=409,retryable=false){super(code);this.code=code;this.status=status;this.retryable=retryable;}}
export const fail=(code,status=409,retryable=false)=>{throw new AuthorityError(code,status,retryable);};
export function openDatabase(config) {
  const db=new DatabaseSync(config.databasePath,{timeout:5000,enableForeignKeyConstraints:true,allowExtension:false});
  try {
    db.exec('PRAGMA busy_timeout=5000; PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON;');
    const version=db.prepare('PRAGMA user_version').get().user_version;
    if(version>1)throw new Error('unsupported database version');
    db.exec(`BEGIN IMMEDIATE;
      CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL) STRICT;
      CREATE TABLE IF NOT EXISTS epoch_allocator(id INTEGER PRIMARY KEY CHECK(id=1),value INTEGER NOT NULL) STRICT;
      INSERT OR IGNORE INTO epoch_allocator VALUES(1,0);
      CREATE TABLE IF NOT EXISTS accounts(account_id TEXT PRIMARY KEY,cloud_space_id TEXT NOT NULL,active_phone_id TEXT NOT NULL,activation_epoch INTEGER NOT NULL,migration_id TEXT NOT NULL DEFAULT '',analytics_enabled INTEGER NOT NULL DEFAULT 0) STRICT;
      CREATE TABLE IF NOT EXISTS devices(device_id TEXT PRIMARY KEY,account_id TEXT NOT NULL,key_id TEXT NOT NULL,public_key TEXT NOT NULL,role TEXT NOT NULL,activation_epoch INTEGER NOT NULL) STRICT;
      CREATE TABLE IF NOT EXISTS active_locks(account_id TEXT PRIMARY KEY,lock_id TEXT NOT NULL UNIQUE,match_id TEXT NOT NULL,recorder_id TEXT NOT NULL,activation_epoch INTEGER NOT NULL) STRICT;
      CREATE TABLE IF NOT EXISTS terminal_locks(account_id TEXT NOT NULL,lock_id TEXT NOT NULL,match_id TEXT NOT NULL,recorder_id TEXT NOT NULL,activation_epoch INTEGER NOT NULL,result TEXT NOT NULL,PRIMARY KEY(account_id,lock_id)) STRICT;
      CREATE TABLE IF NOT EXISTS requests(account_id TEXT NOT NULL,request_id TEXT NOT NULL,operation TEXT NOT NULL,request_digest TEXT NOT NULL,result BLOB NOT NULL,PRIMARY KEY(account_id,request_id)) STRICT;

      CREATE TABLE IF NOT EXISTS challenges(challenge_id TEXT PRIMARY KEY,challenge_hash TEXT NOT NULL,device_id TEXT NOT NULL,key_fingerprint TEXT NOT NULL,expires_at INTEGER NOT NULL,consumed INTEGER NOT NULL) STRICT;
      CREATE TABLE IF NOT EXISTS challenge_requests(request_id TEXT PRIMARY KEY,request_digest TEXT NOT NULL,challenge_id TEXT NOT NULL) STRICT;
      CREATE TABLE IF NOT EXISTS sessions(session_id TEXT PRIMARY KEY,account_id TEXT NOT NULL,device_id TEXT NOT NULL,key_id TEXT NOT NULL,activation_epoch INTEGER NOT NULL,expires_at INTEGER NOT NULL,token_hash TEXT NOT NULL UNIQUE,revoked INTEGER NOT NULL) STRICT;
      CREATE TABLE IF NOT EXISTS auth_records(auth_request_id TEXT NOT NULL,device_id TEXT NOT NULL,account_id TEXT NOT NULL,request_digest TEXT NOT NULL,public_key TEXT NOT NULL,session_id TEXT NOT NULL,public_result BLOB NOT NULL,PRIMARY KEY(auth_request_id,device_id)) STRICT;
      CREATE TABLE IF NOT EXISTS nonces(session_id TEXT NOT NULL,nonce TEXT NOT NULL,PRIMARY KEY(session_id,nonce)) STRICT;
      CREATE TABLE IF NOT EXISTS reauthentications(reauthentication_id TEXT PRIMARY KEY,account_id TEXT NOT NULL,device_id TEXT NOT NULL,key_id TEXT NOT NULL,issued_at INTEGER NOT NULL,expires_at INTEGER NOT NULL,consumed INTEGER NOT NULL) STRICT;

      CREATE TABLE IF NOT EXISTS migrations(migration_id TEXT PRIMARY KEY,account_id TEXT NOT NULL,kind TEXT NOT NULL,state TEXT NOT NULL,old_phone_id TEXT NOT NULL,new_phone_id TEXT NOT NULL,old_epoch INTEGER NOT NULL,cloud_space_id TEXT NOT NULL,requested_at INTEGER NOT NULL,eligible_at INTEGER NOT NULL,checkpoint_id TEXT NOT NULL,content_commitment TEXT NOT NULL) STRICT;
      CREATE TABLE IF NOT EXISTS lost_grants(grant_id TEXT PRIMARY KEY,account_id TEXT NOT NULL,migration_id TEXT NOT NULL,new_phone_id TEXT NOT NULL,key_id TEXT NOT NULL,match_id TEXT NOT NULL,lock_id TEXT NOT NULL,recorder_id TEXT NOT NULL,old_epoch INTEGER NOT NULL,expires_at INTEGER NOT NULL,consumed INTEGER NOT NULL) STRICT;
      CREATE TABLE IF NOT EXISTS peer_grants(grant_id TEXT PRIMARY KEY,account_id TEXT NOT NULL,activation_epoch INTEGER NOT NULL,pairing_id TEXT NOT NULL,local_device_id TEXT NOT NULL,remote_device_id TEXT NOT NULL,result BLOB NOT NULL) STRICT;
      CREATE TABLE IF NOT EXISTS deletions(account_id TEXT PRIMARY KEY,device_id TEXT NOT NULL,delete_request_id TEXT NOT NULL,request_digest TEXT NOT NULL,recovery_hash TEXT NOT NULL,state TEXT NOT NULL,reauthentication_id TEXT NOT NULL,requested_at INTEGER NOT NULL) STRICT;
      CREATE TABLE IF NOT EXISTS deletion_receipts(delete_request_id TEXT NOT NULL,recovery_hash TEXT NOT NULL,result BLOB NOT NULL,expires_at INTEGER NOT NULL,PRIMARY KEY(delete_request_id,recovery_hash)) STRICT;
      CREATE TABLE IF NOT EXISTS qualifications(account_id TEXT PRIMARY KEY,qualification TEXT NOT NULL) STRICT;
      CREATE TABLE IF NOT EXISTS restrictions(account_id TEXT PRIMARY KEY,state TEXT NOT NULL) STRICT;
      CREATE TABLE IF NOT EXISTS analytics_events(account_id TEXT NOT NULL,request_id TEXT NOT NULL,day INTEGER NOT NULL,metric TEXT NOT NULL,count INTEGER NOT NULL,app_version TEXT NOT NULL,os_family TEXT NOT NULL,os_major INTEGER NOT NULL,qualification TEXT NOT NULL,PRIMARY KEY(account_id,request_id)) STRICT;
      CREATE TABLE IF NOT EXISTS analytics_aggregate(day INTEGER NOT NULL,metric TEXT NOT NULL,count INTEGER NOT NULL,PRIMARY KEY(day,metric)) STRICT;
      PRAGMA user_version=1;`);
    const fingerprint=db.prepare('SELECT value FROM metadata WHERE key=?').get('configuration');
    if(fingerprint&&fingerprint.value!==config.fingerprint)throw new Error('persistent key configuration mismatch');
    db.prepare('INSERT OR IGNORE INTO metadata VALUES(?,?)').run('configuration',config.fingerprint);
    db.exec('COMMIT');
    return db;
  }catch(e){if(db.isTransaction)db.exec('ROLLBACK');db.close();throw e;}
}
export function transaction(db,config,body) {
  let committed=false;
  try{
    db.exec('BEGIN IMMEDIATE');
    const result=body();
    if(config.faults?.beforeCommit)fail('unavailable',503,true);
    db.exec('COMMIT'); committed=true;
    if(config.faults?.afterCommitResponseLost)fail('responseLost',503,true);
    return result;
  }catch(e){
    if(!committed&&db.isTransaction)db.exec('ROLLBACK');
    if(e.code==='ERR_SQLITE_ERROR'&&(e.errcode===5||e.errcode===6))fail('unavailable',503,true);
    throw e;
  }
}
export function nextEpoch(db){
  const row=db.prepare('UPDATE epoch_allocator SET value=value+1 WHERE id=1 AND value<9007199254740991 RETURNING value').get();
  if(!row)fail('unavailable',503);return row.value;
}
