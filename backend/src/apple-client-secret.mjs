import {createPrivateKey,sign} from 'node:crypto';
import {canonicalJSON} from './receipt.mjs';
const identifier=value=>typeof value==='string'&&/^[A-Za-z0-9._:-]{1,128}$/.test(value);
export function createAppleClientSecret({teamID,keyID,clientID,privateKey,clock={now:()=>Math.floor(Date.now()/1000)}}) {
  try {
    if(!/^[A-Za-z0-9]{10}$/.test(teamID??'')||!/^[A-Za-z0-9]{10}$/.test(keyID??'')||!identifier(clientID))throw Error();
    const key=typeof privateKey==='string'||Buffer.isBuffer(privateKey)?createPrivateKey(privateKey):privateKey;
    if(key?.type!=='private'||key.asymmetricKeyType!=='ec'||key.asymmetricKeyDetails?.namedCurve!=='prime256v1')throw Error();
    const issuedAt=clock.now();if(!Number.isSafeInteger(issuedAt)||issuedAt<0||issuedAt>Number.MAX_SAFE_INTEGER-300)throw Error();
    const header={alg:'ES256',kid:keyID},claims={iss:teamID,sub:clientID,aud:'https://appleid.apple.com',iat:issuedAt,exp:issuedAt+300};
    const input=Buffer.from(canonicalJSON(header)).toString('base64url')+'.'+Buffer.from(canonicalJSON(claims)).toString('base64url');
    const signature=sign('sha256',Buffer.from(input),{key,dsaEncoding:'ieee-p1363'});
    if(signature.length!==64)throw Error();return input+'.'+signature.toString('base64url');
  } catch {throw new Error('invalid Apple client secret configuration');}
}
