const filename={{movie.filename|tojson}};
let isWatched={{1 if movie.percent >= 90 else 0}};
const movieDur={{movie.duration or (movie.runtime*60 if movie.runtime else 0)}};
const moviePos={{movie.position or 0}};

function updateEndsAt(){
  const el=document.getElementById('endsAtBadge');
  if(!el)return;
  const rem=Math.max(0,movieDur-moviePos);
  if(rem>60){
    const end=new Date(Date.now()+rem*1000);
    let hours=end.getHours();
    const minutes=String(end.getMinutes()).padStart(2,'0');
    const ampm=hours>=12?'PM':'AM';
    hours=hours%12||12;
    el.textContent=`Ends at ${hours}:${minutes} ${ampm}`;
    el.style.display='inline-flex';
  }
}
updateEndsAt();

function toggleWatched(){
  const btn=document.getElementById('watchToggleBtn');
  const badge=document.getElementById('watchStatusBadge');
  const playBtn=document.getElementById('playBtn');
  const newPos=isWatched?0:(movieDur||100);
  const newDur=movieDur||100;
  btn.disabled=true;
  fetch('/api/progress',{
    method:'POST',
    headers:{'Content-Type':'application/json'},
    body:JSON.stringify({filename:filename,position:newPos,duration:newDur})
  }).then(r=>r.json()).then(()=>{
    isWatched=!isWatched;
    btn.disabled=false;
    if(isWatched){
      btn.textContent='Mark Unwatched';
      if(badge){badge.className='badge-status status-watched';badge.textContent='Watched ✓';}
      if(playBtn)playBtn.innerHTML='▶ Play';
    }else{
      btn.textContent='✓ Mark Watched';
      if(badge){badge.className='badge-status status-unwatched';badge.textContent='Unwatched';}
      if(playBtn)playBtn.innerHTML='▶ Play';
    }
  }).catch(()=>{btn.disabled=false;});
}

function openTrailer(key){
  const modal=document.getElementById('trailerModal');
  const iframe=document.getElementById('trailerIframe');
  if(!modal||!iframe||!key)return;
  iframe.src='https://www.youtube-nocookie.com/embed/'+key+'?autoplay=1';
  modal.hidden=false;
  document.body.style.overflow='hidden';
}

function closeTrailer(){
  const modal=document.getElementById('trailerModal');
  const iframe=document.getElementById('trailerIframe');
  if(iframe)iframe.src='';
  if(modal)modal.hidden=true;
  document.body.style.overflow='';
}

document.addEventListener('keydown',e=>{
  if(e.key==='Escape')closeTrailer();
});
