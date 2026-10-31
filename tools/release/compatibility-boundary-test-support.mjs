import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {computeProteanPublicationBoundary} from './publication-boundary.mjs';
import {impactBlock,impactInput} from './impact.mjs';
import {retainedFixture} from './promotion-test-support.mjs';
import {expectedReviewSettings} from './review-check.mjs';

export async function computedCompatibilityBoundary(){
  const repository='tkersey/protean',repositoryId=1328996555,oid=n=>n.toString(16).padStart(40,'0');
  const commits=new Map([0,1,2,3].map(n=>[oid(n),{sha:oid(n),tree:{sha:oid(n===2?23:n+20)},
    parents:n===0?[]:[{sha:oid(n===3?1:n-1)}]}]));
  const source={commit:oid(3),tree:oid(23)},bootstrap={base:oid(0),head:oid(1),tree:oid(21)},subject={base:oid(1),head:oid(2),tree:oid(23)};
  const declaration={impact:'patch',disposition:'compatible',rationale:'Synthetic original review.',contracts:['fixture API']};
  const body=impactBlock(declaration),reviews=new Map();
  for(const [index,range] of [bootstrap,subject].entries()){
    const context={repository,...range,impact:impactInput(body,range.base,range.head),
      ...(index===0?{bootstrap:{boundary:range,initialVersion:'8.0.0',disposition:'compatible',rationale:'Synthetic bootstrap review.'}}:{pullNumber:1})};
    const retained=retainedFixture(context,expectedReviewSettings);
    const envelope={schema:'repository-review-result/v1',status:'complete',epochClosed:true,reason:'Synthetic owner complete.',
      turn:1,previousSha256:null,stateSha256:null,context,retainedEvidence:Buffer.from(JSON.stringify(retained)).toString('base64')};
    reviews.set(range.head,{bytes:Buffer.from(JSON.stringify(envelope)),run:{id:index+1},artifact:{id:index+3}});
  }
  const pull={id:5,number:1,state:'closed',merged:true,merged_at:'2026-10-30T00:00:00Z',body,merge_commit_sha:source.commit,
    base:{ref:'main',sha:subject.base,repo:{id:repositoryId}},head:{sha:subject.head,repo:{id:repositoryId}}};
  const forward=(base,head)=>{
    let cursor=head;
    while(cursor!==undefined){if(cursor===base)return true;cursor=commits.get(cursor)?.parents[0]?.sha;}
    return false;
  };
  const client={async request({path}){
    const reply=body=>({status:200,body:structuredClone(body)});
    if(path==='')return reply({full_name:repository,id:repositoryId,default_branch:'main'});
    if(path==='/git/ref/heads/main')return reply({ref:'refs/heads/main',object:{type:'commit',sha:source.commit}});
    if(path.startsWith('/git/commits/'))return reply(commits.get(path.slice(13)));
    if(path.startsWith('/contents/build.zig.zon?ref=')){
      const version=Number.parseInt(path.split('=')[1],16)>=2?'8.0.1':'8.0.0',bytes=Buffer.from(JSON.stringify({version}));
      return reply({type:'file',encoding:'base64',content:bytes.toString('base64'),
        sha:createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex')});
    }
    if(path.startsWith('/releases/tags/'))return {status:404};
    if(path==='/releases?per_page=100&page=1')return reply([]);
    const comparison=/^\/compare\/([a-f0-9]{40})\.\.\.([a-f0-9]{40})$/.exec(path);
    if(comparison){const [,base,head]=comparison;return reply({base_commit:{sha:base},merge_base_commit:{sha:forward(base,head)?base:oid(0)},status:base===head?'identical':forward(base,head)?'ahead':'diverged'});}
    if(path===`/commits/${source.commit}/pulls?per_page=100&page=1`)return reply([pull]);
    if(path==='/pulls/1')return reply(pull);
    if(path==='/pulls/1/commits?per_page=100&page=1')return reply([{sha:subject.head}]);
    assert.fail('unexpected boundary API '+path);
  }};
  const boundary=await computeProteanPublicationBoundary({source,bootstrap},{client,
    admitPublishedRelease:async()=>assert.fail('first publication has no predecessor'),
    authenticateReview:async value=>{assert.equal(value.base,value.head===bootstrap.head?bootstrap.base:subject.base);return reviews.get(value.head);},
    readVersion:async({manifestBytes})=>JSON.parse(manifestBytes).version,
    classifyVersionPreparation:async()=>({versionOnly:true})});
  return {boundary,repository,commits,forward,selected:{commit:bootstrap.base,tree:commits.get(bootstrap.base).tree.sha}};
}
