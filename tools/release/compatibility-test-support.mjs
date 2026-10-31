import {encodeRecord,sha256} from './encoding.mjs';

export function attachCompatibility(record,base,{baseline=null,changes,bootstrap=true}={}){
  const {impact,disposition}=record.compatibility;
  const declaration={impact,disposition,rationale:'Synthetic authenticated compatibility fixture.',contracts:['fixture API']};
  const subject={base,head:record.source.commit,tree:record.source.tree};
  const review={runId:1,artifactId:2,sha256:'a'.repeat(64)};
  const boundary={schema:'repository-publication-boundary/v1',repository:record.repository.name,
    source:{commit:record.source.commit,tree:record.source.tree},pendingVersion:record.source.version,
    version:record.source.version,status:'ready',baseline,
    bootstrap:baseline===null&&bootstrap?{subject,initialVersion:record.source.version,disposition,
      rationale:declaration.rationale,declaration,review,correspondence:null}:null,
    changes:changes??(baseline===null?[]:[{base,head:subject.head,pull:1,subject,landedCommits:[subject.head],review,declaration,versionOnly:false}])};
  const bytes=encodeRecord(boundary),name='publication-boundary.json';
  record.compatibility.evidence=name;
  record.artifacts=record.artifacts.filter(value=>value.name!==name);
  record.artifacts.push({name,role:'evidence',platform:null,bytes:bytes.length,sha256:sha256(bytes)});
  return new Map([[name,bytes]]);
}
