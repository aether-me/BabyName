const test=require("node:test");
const assert=require("node:assert/strict");
const fs=require("node:fs");

const select=(candidates,votes,strict)=>candidates.filter(name=>{
  const picks=votes.filter(v=>v.name===name&&v.choice===1);
  return strict?picks.length===2:picks.length>0;
});
const pairs=names=>names.flatMap((left,i)=>names.slice(i+1).map(right=>`${left}|${right}`));
const nextRound=(stage,attempt,candidates,votes)=>{
  const survivors=select(candidates,votes,stage>=3);
  if(!survivors.length)return {stage,attempt:attempt+1,kind:"screen",candidates};
  if(stage>=3&&survivors.length<=5)return {stage:stage+1,attempt:1,kind:"final",candidates:survivors};
  return {stage:stage+1,attempt:1,kind:"screen",candidates:survivors};
};
const recordVote=(votes,vote)=>[...votes.filter(v=>v.name!==vote.name),vote];
const finishSwipe=(dx,cancelled)=>cancelled||Math.abs(dx)<=90?null:dx>0?1:-1;
const guard=()=>{let busy=false,calls=0;return {submit(){if(busy)return false;busy=true;calls++;return true},done(){busy=false},get calls(){return calls}}};
const validCandidates=candidates=>Array.isArray(candidates)&&candidates.length>0&&candidates.length<=150&&candidates.every(item=>item&&typeof item==="object"&&typeof item.name==="string"&&item.name.trim()===item.name&&item.name.length>0)&&new Set(candidates.map(item=>item.name)).size===candidates.length;
const confirm=(decisions,user,name)=>{
  const common=[...new Set(decisions.map(d=>d.name))].find(value=>decisions.filter(d=>d.name===value).length===2);
  if(common&&common!==name)throw new Error("common decision is locked");
  const next=[...decisions.filter(d=>d.user!==user),{user,name}];
  const selected=[...new Set(next.map(d=>d.name))].find(value=>next.filter(d=>d.name===value).length===2);
  return {decisions:next,isCommon:Boolean(selected),name:selected||name};
};

test("rounds 1–2 keep the union of positive votes",()=>{
  assert.deepEqual(select(["А","Б"],[{name:"А",choice:1}],false),["А"]);
});
test("round 3 keeps only names liked by both",()=>{
  assert.deepEqual(select(["А","Б"],[{name:"А",choice:1},{name:"А",choice:1},{name:"Б",choice:1}],true),["А"]);
});
test("an empty early round repeats the same stage and retains its candidates",()=>{
  assert.deepEqual(nextRound(2,1,["А","Б"],[]),{stage:2,attempt:2,kind:"screen",candidates:["А","Б"]});
});
test("an empty strict round creates a controlled reconsider attempt",()=>{
  assert.deepEqual(nextRound(3,2,["А","Б"],[{name:"А",choice:1}]),{stage:3,attempt:3,kind:"screen",candidates:["А","Б"]});
});
test("up to five shared candidates enter the final",()=>{
  assert.deepEqual(nextRound(3,1,["А","Б"],[{name:"А",choice:1},{name:"А",choice:1}]),{stage:4,attempt:1,kind:"final",candidates:["А"]});
});
test("final pairs are unique and cover all pairs",()=>{
  assert.deepEqual(pairs(["А","Б","В"]),["А|Б","А|В","Б|В"]);
  assert.equal(pairs(["А","Б","В","Г","Д"]).length,10);
});
test("one finalist produces no pair comparison",()=>assert.deepEqual(pairs(["А"]),[]));
test("initial candidate list rejects duplicates, blank names and invalid objects",()=>{
  assert.equal(validCandidates([{name:"А"},{name:"Б"}]),true);
  assert.equal(validCandidates([{name:"А"},{name:"А"}]),false);
  assert.equal(validCandidates([{name:" "}]),false);
  assert.equal(validCandidates([{name:" А"}]),false);
  assert.equal(validCandidates([{"name":1}]),false);
});
test("repeated vote replaces the previous choice instead of adding a second vote",()=>{
  assert.deepEqual(recordVote([{name:"А",choice:-1}],{name:"А",choice:1}),[{name:"А",choice:1}]);
});
test("cancelled swipe never produces a choice and normal swipes keep direction",()=>{
  assert.equal(finishSwipe(160,true),null);
  assert.equal(finishSwipe(89,false),null);
  assert.equal(finishSwipe(100,false),1);
  assert.equal(finishSwipe(-100,false),-1);
});
test("busy guard allows only one in-flight submission",()=>{
  const state=guard();
  assert.equal(state.submit(),true);
  assert.equal(state.submit(),false);
  assert.equal(state.calls,1);
  state.done();
  assert.equal(state.submit(),true);
  assert.equal(state.calls,2);
});
test("a common decision needs equal confirmations and cannot be changed afterwards",()=>{
  const first=confirm([],"u1","А");
  assert.equal(first.isCommon,false);
  const common=confirm(first.decisions,"u2","А");
  assert.deepEqual({isCommon:common.isCommon,name:common.name},{isCommon:true,name:"А"});
  assert.throws(()=>confirm(common.decisions,"u1","Б"),/locked/);
});
test("serialized simultaneous confirmations keep equal choice common and different choices separate",()=>{
  const sameSecond=confirm(confirm([],"u1","А").decisions,"u2","А");
  assert.equal(sameSecond.isCommon,true);
  const differentSecond=confirm(confirm([],"u1","А").decisions,"u2","Б");
  assert.deepEqual({isCommon:differentSecond.isCommon,name:differentSecond.name},{isCommon:false,name:"Б"});
});
test("migration keeps direct writes revoked and grants only intended RPC access",()=>{
  const sql=fs.readFileSync("supabase/migrations/20261106_secure_selection_progression.sql","utf8");
  assert.match(sql,/revoke all on table public\.name_selection_rounds,public\.name_selection_votes/);
  assert.match(sql,/grant select on table public\.name_selection_rounds,public\.name_selection_votes/);
  assert.match(sql,/revoke all on function public\.confirm_selection_decision\(uuid,text\) from public,anon/);
  assert.match(sql,/grant execute on function public\.confirm_selection_decision\(uuid,text\) to authenticated/);
  assert.match(sql,/select \* into r from public\.name_selection_rounds where id=p_round for update/);
  assert.match(sql,/set search_path=''/);
  assert.match(sql,/jsonb_array_elements\(p_candidates\).*group by c->>'name' having count\(\*\)>1/s);
  assert.match(sql,/from pg_catalog\.pg_policy/);
});
test("selection catalogue has 150 unique non-empty male names with forms",()=>{
  const source=fs.readFileSync("rounds.js","utf8");
  const entries=[...source.matchAll(/\{name:"([^"]+)",forms:\[([^\]]+)\]\}/g)];
  const names=entries.map(match=>match[1]);
  assert.equal(entries.length,150);
  assert.equal(new Set(names).size,150);
  assert.ok(entries.every(match=>match[1].trim()===match[1]&&match[2].includes('"')));
});
