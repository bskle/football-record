import {mkdtempSync,writeFileSync,chmodSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
export function localCertificate(){
 const directory=mkdtempSync(join(tmpdir(),'football-local-tls-')),keyFile=join(directory,'key.pem'),certFile=join(directory,'cert.pem'),config=join(directory,'openssl.cnf');
 writeFileSync(config,'[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=localhost\n[v3]\nsubjectAltName=DNS:localhost\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\nextendedKeyUsage=serverAuth\n',{mode:0o600});
 const result=spawnSync('openssl',['req','-x509','-newkey','rsa:2048','-nodes','-days','1','-config',config,'-keyout',keyFile,'-out',certFile],{stdio:'ignore'});if(result.status!==0)throw Error('local certificate unavailable');chmodSync(keyFile,0o600);chmodSync(certFile,0o600);return {keyFile,certFile};
}
