"use strict";
(function(){
var reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
var DW=1280, DH=720, MODE="target", STATE="working", ROOM="builder", AGENT="claude";
/* BOX is the identity — the roster's box NAME, not a label derived from
   agent+role. Those coincide in the current fleet (claude-builder is both),
   which is exactly why deriving it survived this long: nothing in the roster
   format requires it, and when they diverge the console labels one box while
   its controls drive another. Set by drawCell (per cell) and focusUnit. */
var BOX="claude-builder";
function UNITID(u){return u.box||(u.agent+"-"+u.room);}
function UNIT(){return BOX;}
function ROLEWORD(){return ROOM;}
var lastHand={x:260,y:400};

function oc(w,h){var c=document.createElement("canvas");c.width=w;c.height=h;return c;}
var scene=oc(DW,DH), S=scene.getContext("2d");
var glow =oc(DW,DH), G=glow.getContext("2d");
var comp =oc(DW,DH), C=comp.getContext("2d");
var tintR=oc(DW,DH), tintG=oc(DW,DH), tintB=oc(DW,DH);
var RW=520,RH=600;
var robo=oc(RW,RH), RB=robo.getContext("2d");
var remit=oc(RW,RH), RE=remit.getContext("2d");
var rrim=oc(RW,RH), RR=rrim.getContext("2d");
var noise=makeNoise(220);

function rgba(r,g,b,a){return "rgba("+r+","+g+","+b+","+a+")";}
function rr(c,x,y,w,h,r){c.beginPath();if(c.roundRect){c.roundRect(x,y,w,h,r);}else{c.moveTo(x+r,y);c.arcTo(x+w,y,x+w,y+h,r);c.arcTo(x+w,y+h,x,y+h,r);c.arcTo(x,y+h,x,y,r);c.arcTo(x,y,x+w,y,r);c.closePath();}}
function poly(c,pts){c.beginPath();for(var i=0;i<pts.length;i++){if(i)c.lineTo(pts[i][0],pts[i][1]);else c.moveTo(pts[i][0],pts[i][1]);}c.closePath();}
function plate(c,pts,top,bot,ed){var y0=1e9,y1=-1e9;for(var i=0;i<pts.length;i++){if(pts[i][1]<y0)y0=pts[i][1];if(pts[i][1]>y1)y1=pts[i][1];}var gg=c.createLinearGradient(0,y0,0,y1);gg.addColorStop(0,top);gg.addColorStop(1,bot);poly(c,pts);c.fillStyle=gg;c.fill();if(ed){c.strokeStyle=ed;c.lineWidth=1.2;c.lineJoin="round";c.stroke();}}
function pl(c,x0,y0,x1,y1,col,w){c.strokeStyle=col;c.lineWidth=w||1;c.beginPath();c.moveTo(x0,y0);c.lineTo(x1,y1);c.stroke();}
function rivet(c,x,y,col){c.fillStyle=col;c.beginPath();c.arc(x,y,1.5,0,7);c.fill();}
function makeNoise(n){var c=oc(n,n),x=c.getContext("2d"),d=x.createImageData(n,n),p=d.data;for(var i=0;i<p.length;i+=4){var v=Math.random()*255;p[i]=p[i+1]=p[i+2]=v;p[i+3]=255;}x.putImageData(d,0,0);return c;}
function fnoise(t){return Math.sin(t*11.3)*0.5+Math.sin(t*23.7+1.3)*0.3+Math.sin(t*57.1+0.7)*0.2;}

var motes=[];for(var i=0;i<90;i++)motes.push({x:Math.random(),y:Math.random(),z:.3+Math.random()*.9,s:Math.random()*6.28});
var steam=[];for(var i=0;i<26;i++)steam.push({p:Math.random(),x:.72+Math.random()*.12,sway:Math.random()*6.28});
var floorHaze=[];for(var i=0;i<5;i++)floorHaze.push({x:Math.random(),sp:.006+Math.random()*.01,y:.80+i*.03,a:.05+Math.random()*.05});
var sparks=[];

var LAMPX=470,LAMPY=70,FLOORY=612,ROBOX=470,ROBOY=FLOORY;
var HOLOX=800,HOLOY=250,HOLOW=250,HOLOH=196;
var lamp={lit:1,drop:0};
function stepLamp(t,dt,on){ if(reduced){lamp.lit=on?1:0;return;} if(!on){lamp.lit=0;return;} var base=0.86+0.14*fnoise(t*0.9); if(lamp.drop>0){lamp.drop-=dt;lamp.lit=0.12+0.08*Math.random();} else{lamp.lit=base;if(Math.random()<0.012)lamp.drop=0.04+Math.random()*0.12;} }
function emit(fn){fn(S);fn(G);}

/* ===================== BUILDER PROPS ===================== */
function crate(c,x,y){plate(c,[[x,y],[x+16,y],[x+16,y+14],[x,y+14]],"#3a2c1a","#160f08","#4a3826");c.fillStyle="rgba(201,162,39,0.4)";c.fillRect(x+2,y+3,12,2);}
function crateBig(x,y){plate(S,[[x,y],[x+42,y],[x+42,y+42],[x,y+42]],"#33271a","#130d07","#463526");S.strokeStyle="rgba(0,0,0,0.45)";S.lineWidth=1;S.strokeRect(x+6,y+6,30,30);S.fillStyle="rgba(201,162,39,0.32)";S.fillRect(x+8,y+17,26,3);S.fillStyle="rgba(255,200,140,0.05)";S.fillRect(x,y,42,2);}
function floorHazard(){var x=356,y=620,w=268;S.save();S.globalAlpha=0.5;for(var s=x;s<x+w;s+=18){S.fillStyle=(s-x)%36<18?"rgba(201,162,39,0.5)":"rgba(0,0,0,0)";S.fillRect(s,y,10,4);S.fillRect(s,y+40,10,4);}S.restore();S.strokeStyle="rgba(201,162,39,0.14)";S.lineWidth=1;S.strokeRect(x,y,w,40);}
function crane(t){
  var railY=120,x0=250,x1=690;
  S.fillStyle="#121826";S.fillRect(x0,railY,x1-x0,10);S.fillStyle="#222d3c";S.fillRect(x0,railY,x1-x0,3);
  for(var i=x0+10;i<x1;i+=40){S.fillStyle="#0a0f16";S.fillRect(i,railY+10,6,4);}
  var tx=470;  // static + integer-aligned: a striped girder can't move without its edges aliasing
  S.fillStyle="#28303c";S.fillRect(tx-14,railY-2,28,14);
  S.strokeStyle="#3a465e";S.lineWidth=2;S.beginPath();S.moveTo(tx,railY+12);S.lineTo(tx,railY+70);S.stroke();
  S.fillStyle="#1a2230";S.fillRect(tx-8,railY+70,16,10);
  // the hook's warning light is the living element (a smooth glow — no aliasing)
  emit(function(c){var p=0.35+0.65*Math.pow(Math.max(0,Math.sin(t*2)),2);c.fillStyle=rgba(255,60,50,0.9*p);c.beginPath();c.arc(tx,railY+80,2.5,0,7);c.fill();var g7=c.createRadialGradient(tx,railY+80,1,tx,railY+80,10);g7.addColorStop(0,rgba(255,60,50,0.5*p));g7.addColorStop(1,"rgba(255,60,50,0)");c.fillStyle=g7;c.beginPath();c.arc(tx,railY+80,10,0,7);c.fill();});
  var gy=railY+92;for(var s=tx-56;s<tx+56;s+=14){S.fillStyle=((s-tx+56)%28<14)?"#c9a227":"#0f1420";S.fillRect(s,gy,14,12);}
  S.fillStyle="rgba(0,0,0,0.4)";S.fillRect(tx-60,gy+12,120,3);
}
function rightTower(t){
  var x=1150,w=66,yb=612,yt=372,seg=(yb-yt-26)/9;
  plate(S,[[x,yt],[x+w,yt],[x+w,yb],[x,yb]],"#141b28","#080c14","#20303f");
  S.fillStyle="#20293a";S.fillRect(x,yt,w,5);
  for(var u=0;u<9;u++){var uy=yt+14+u*seg;S.fillStyle="#0a0f18";S.fillRect(x+7,uy,w-14,seg-3);S.fillStyle="#12203a";S.fillRect(x+9,uy+1,10,2);
    if(u%2===0){var on=Math.sin(t*2+u)>0.2;var col=[[95,206,155],[95,180,255],[247,189,78]][u%3];emit(function(c){c.fillStyle=rgba(col[0],col[1],col[2],(on?0.62:0.14));c.fillRect(x+w-13,uy+2,4,3);});}
  }
  // side rim sliver + a faint key-light spill so it isn't pure black
  emit(function(c){c.fillStyle="rgba(95,214,255,0.10)";c.fillRect(x-1,yt,1,yb-yt);});
  S.fillStyle="rgba(120,150,180,0.05)";S.fillRect(x,yt,4,yb-yt);
  // hanging cable up to ceiling
  S.strokeStyle="#0d1520";S.lineWidth=3;S.beginPath();S.moveTo(x+w-10,yt);S.quadraticCurveTo(x+w+16,yt-46,x+w+8,yt-96);S.stroke();
  contactShadow(x+w/2,yb,w);
}
function contactShadow(cx,by,w){S.save();var g2=S.createRadialGradient(cx,by,2,cx,by,w*0.8);g2.addColorStop(0,"rgba(0,0,0,0.5)");g2.addColorStop(1,"rgba(0,0,0,0)");S.fillStyle=g2;S.beginPath();S.ellipse(cx,by+2,w*0.7,10,0,0,7);S.fill();S.restore();}
function fabBay(t,lit,st){
  var x=258,w=114,yt=430,yb=612,on=st!=="offline";
  plate(S,[[x,yt],[x+w,yt],[x+w,yb],[x,yb]],"#1b2330","#090d14","#2a3444");
  S.fillStyle="rgba(201,162,39,0.5)";S.fillRect(x+6,yt+6,w-12,8);
  var cxa=x+16,cya=yt+28,cw=w-32,ch=112;
  S.fillStyle="#04070c";S.fillRect(cxa,cya,cw,ch);S.strokeStyle="#2a3444";S.lineWidth=1;S.strokeRect(cxa,cya,cw,ch);
  var head=0.5+0.5*Math.sin(t*(st==="working"?4:1)),px=cxa+8+head*(cw-24);
  emit(function(c){if(!on)return;var pg=c.createLinearGradient(0,cya+ch-44,0,cya+ch);pg.addColorStop(0,rgba(255,180,90,0.7*(st==="working"?1:0.5)));pg.addColorStop(1,rgba(255,120,40,0.2));c.fillStyle=pg;c.fillRect(cxa+cw/2-10,cya+ch-46,20,42);
    c.fillStyle=rgba(150,210,255,st==="working"?0.9:0.3);c.fillRect(px,cya+18,3,3);
    var ig=c.createRadialGradient(cxa+cw/2,cya+ch-22,2,cxa+cw/2,cya+ch-22,cw*0.7);ig.addColorStop(0,rgba(255,160,70,0.28*(st==="working"?1:0.45)));ig.addColorStop(1,"rgba(255,160,70,0)");c.fillStyle=ig;c.fillRect(cxa,cya,cw,ch);});
  S.strokeStyle="#3a465e";S.lineWidth=1;S.beginPath();S.moveTo(cxa+4,cya+16);S.lineTo(cxa+cw-4,cya+16);S.stroke();
  S.fillStyle="#28303c";S.fillRect(px-1,cya+14,5,5);
  emit(function(c){c.fillStyle=on?rgba(95,206,155,0.9):rgba(255,60,50,0.8);c.beginPath();c.arc(x+w-12,yt+22,3,0,7);c.fill();});
  rivet(S,x+6,yt+3,"#3d4c63");rivet(S,x+w-6,yt+3,"#3d4c63");
  // barrels beside the bay
  [[x+w+6,"#c9a227"],[x+w+18,"#4f9e5a"]].forEach(function(k){var bx=k[0];plate(S,[[bx,566],[bx+11,566],[bx+11,612],[bx,612]],k[1],"#0c1119","#0a0e16");S.fillStyle="rgba(0,0,0,0.4)";S.fillRect(bx,576,11,1);S.fillRect(bx,596,11,1);});
}
function pegboard(t,lit){
  var x=560,y=250,w=94,h=70;
  plate(S,[[x,y],[x+w,y],[x+w,y+h],[x,y+h]],"#2a1f12","#160f08","#3a2c1a");
  S.fillStyle="rgba(0,0,0,0.4)";for(var i=0;i<7;i++)for(var j=0;j<4;j++)S.fillRect(x+10+i*11,y+9+j*14,2,2);
  var tc=["#8a939e","#c9a227","#b0563a","#5a9e6a"];
  for(var k=0;k<4;k++){var tx=x+14+k*20;S.fillStyle="#0a0f16";S.fillRect(tx,y+12,3,32);S.fillStyle=tc[k];S.fillRect(tx-3,y+38,9,10);}
  S.fillStyle="rgba(255,200,140,"+(0.06*lit)+")";S.fillRect(x,y,w,2);
}
function conveyor(t,st){
  var x=566,y=558,w=236,run=st==="working";
  S.fillStyle="#0f1520";S.fillRect(x+12,y+12,8,42);S.fillRect(x+w-20,y+12,8,42);
  plate(S,[[x,y],[x+w,y],[x+w,y+12],[x,y+12]],"#202836","#0d131e","#2a3444");
  var off=run?(t*40)%16:0;S.fillStyle="#0a0f16";S.fillRect(x+2,y+3,w-4,7);
  S.fillStyle="#161d29";for(var i=x+2-16+off;i<x+w;i+=16)S.fillRect(i,y+3,8,7);
  var coff=run?(t*40)%80:20;for(var c=0;c<3;c++){var cx2=x+10+((c*80+coff)%(w-26));crate(S,cx2,y-14);}
  emit(function(cc){cc.fillStyle=run?rgba(95,206,155,0.9):rgba(120,130,140,0.35);cc.beginPath();cc.arc(x+6,y+6,2.5,0,7);cc.fill();});
}
function workbench(t,lit,st){
  var x=372,y=566,w=204;
  S.fillStyle="#0d1119";S.fillRect(x+10,y+12,8,34);S.fillStyle="#0d1119";S.fillRect(x+w-18,y+12,8,34);
  plate(S,[[x,y],[x+w,y],[x+w,y+12],[x,y+12]],"#252d3a","#111823","#313c4e");
  S.fillStyle="#28303c";S.fillRect(x+34,y-8,14,10);       // vise
  plate(S,[[x+w-52,y-30],[x+w-14,y-30],[x+w-14,y-4],[x+w-52,y-4]],"#12202e","#0a1420","#22304a"); // task monitor
  emit(function(c){var on=st!=="offline";var col=st==="working"?[247,189,78]:st==="offline"?[120,60,60]:[90,150,210];c.fillStyle=rgba(col[0],col[1],col[2],on?0.42:0.28);c.fillRect(x+w-48,y-26,30,18);c.fillStyle=rgba(col[0],col[1],col[2],on?0.6:0.3);var sw2=[22,14,18];for(var sl2=0;sl2<3;sl2++)c.fillRect(x+w-46,y-24+sl2*5,sw2[sl2],1);});
  S.fillStyle="rgba(200,210,225,"+(0.12*lit)+")";S.fillRect(x+74,y-3,20,2);
  // toolbox on the floor by the bench
  var tb=x+w-6,ty=592;plate(S,[[tb,ty],[tb+34,ty],[tb+34,ty+18],[tb,ty+18]],"#7a2c1e","#3a1710","#a8402a");S.fillStyle="#1a0a06";S.fillRect(tb+2,ty+6,30,2);
}

/* ===================== REVIEWER PROPS (clinical lab) ===================== */
function diffWall(t,st){
  var x=262,y=176,mw=80,gap=12,mh=132,off=st==="offline",scroll=off?0:(t*(st==="working"?20:6));
  for(var i=0;i<4;i++){var mx=x+i*(mw+gap);
    plate(S,[[mx,y],[mx+mw,y],[mx+mw,y+mh],[mx,y+mh]],"#0c1220","#060a12","#22304a");
    S.fillStyle="#07121e";S.fillRect(mx+4,y+4,mw-8,mh-8);
    for(var l=0;l<17;l++){var ly=y+8+((l*9+scroll)%(mh-14));var k=(i+l)%4;var cr=k===0?90:k===1?210:70,cg=k===0?200:k===1?90:110,cb=k===0?120:k===1?90:150;var lw=Math.min(14+((i*7+l*13)%48),mw-14);S.fillStyle=rgba(cr,cg,cb,off?0.12:0.5);S.fillRect(mx+7,ly,lw,2);G.fillStyle=rgba(cr,cg,cb,off?0.05:0.34);G.fillRect(mx+7,ly,lw,2);}
    if(!off){var gg=S.createRadialGradient(mx+mw/2,y+mh/2,4,mx+mw/2,y+mh/2,mw*0.9);gg.addColorStop(0,"rgba(90,160,220,0.09)");gg.addColorStop(1,"rgba(90,160,220,0)");S.fillStyle=gg;S.fillRect(mx-8,y-8,mw+16,mh+16);}
    S.fillStyle=off?"#3a1518":"#1a3a2a";S.fillRect(mx+mw-11,y+mh-6,6,3);
  }
}
function checklistBoard(){
  var x=566,y=252,w=88,h=76;plate(S,[[x,y],[x+w,y],[x+w,y+h],[x,y+h]],"#0f1620","#0a0f16","#22304a");S.fillStyle="#131c26";S.fillRect(x+5,y+5,w-10,h-10);
  for(var i=0;i<6;i++){S.fillStyle=i<4?"#4a8a5e":"#38424e";S.fillRect(x+9,y+11+i*11,4,4);S.fillStyle="#39434f";S.fillRect(x+17,y+12+i*11,w-28,2);}
}
function inspectDesk(t,st){
  var x=372,y=566,w=204,off=st==="offline";
  plate(S,[[x,y],[x+w,y],[x+w,y+12],[x,y+12]],"#26303e","#121a24","#33404f");
  S.fillStyle="#0d1119";S.fillRect(x+10,y+12,8,34);S.fillRect(x+w-18,y+12,8,34);
  S.fillStyle="rgba(202,212,226,0.5)";S.fillRect(x+36,y-5,30,5);S.fillStyle="rgba(150,166,186,0.42)";S.fillRect(x+40,y-9,22,4);
  var ax=x+w-48,yl=y-2;
  S.strokeStyle="#3a465e";S.lineWidth=2;S.beginPath();S.moveTo(ax,y);S.lineTo(ax+4,yl-24);S.lineTo(ax+26,yl-33);S.stroke();
  S.fillStyle="#1a2230";S.beginPath();S.arc(ax+31,yl-33,9,0,7);S.fill();
  if(!off)emit(function(c){var g3=c.createRadialGradient(ax+31,yl-33,1,ax+31,yl-33,17);g3.addColorStop(0,"rgba(196,232,255,0.55)");g3.addColorStop(1,"rgba(196,232,255,0)");c.fillStyle=g3;c.beginPath();c.arc(ax+31,yl-33,17,0,7);c.fill();});
  S.strokeStyle="rgba(196,232,255,0.5)";S.lineWidth=1;S.beginPath();S.arc(ax+31,yl-33,7,0,7);S.stroke();
}
function verdictTower(t,st){
  var x=632,pt=496,baseY=612;
  S.fillStyle="#0f1520";S.fillRect(x+4,pt+48,6,baseY-(pt+48));
  contactShadow(x+7,baseY,26);
  plate(S,[[x,pt],[x+14,pt],[x+14,pt+48],[x,pt+48]],"#141b26","#0a0f16","#22304a");
  var LT=[["255,77,71",st==="offline"],["247,189,78",st==="working"],["79,208,122",st==="idle"]];
  for(var i=0;i<3;i++){var ly=pt+4+i*15,on=LT[i][1],col=LT[i][0];
    if(on)emit(function(c){c.fillStyle="rgba("+col+",0.92)";c.fillRect(x+3,ly,8,10);var g4=c.createRadialGradient(x+7,ly+5,1,x+7,ly+5,16);g4.addColorStop(0,"rgba("+col+",0.5)");g4.addColorStop(1,"rgba("+col+",0)");c.fillStyle=g4;c.beginPath();c.arc(x+7,ly+5,16,0,7);c.fill();});
    else{S.fillStyle="#0e141c";S.fillRect(x+3,ly,8,10);}
  }
}
function fileCabinet(x){var y=612-58;plate(S,[[x,y],[x+34,y],[x+34,612],[x,612]],"#2a3340","#12181f","#3a4656");for(var d=0;d<3;d++){S.fillStyle="#0e141c";S.fillRect(x+4,y+7+d*17,26,13);S.fillStyle="#5a6a80";S.fillRect(x+13,y+12+d*17,8,2);}contactShadow(x+17,612,34);}
function docStack(x){for(var i=0;i<5;i++){S.fillStyle=i%2?"#cbd4e0":"#adb8c6";S.fillRect(x-(i%2),612-6-i*4,26,4);}S.fillStyle="rgba(0,0,0,0.3)";S.fillRect(x,612-2,26,2);}

/* ===================== TRIAGE PROPS (dispatch room) ===================== */
function kanban(t,st){
  var x=268,y=178,w=344,h=128,off=st==="offline",colw=(w-24)/4;
  plate(S,[[x,y],[x+w,y],[x+w,y+h],[x,y+h]],"#20262e","#0e1216","#3a4048");
  S.fillStyle="#2f353c";S.fillRect(x+6,y+6,w-12,h-12);S.fillStyle="#3a4149";S.fillRect(x+6,y+6,w-12,1);
  var cols=["247,189,78","92,180,255","201,139,255","95,206,155"];
  for(var c=0;c<4;c++){var cx2=x+12+c*colw;S.fillStyle="#242a30";S.fillRect(cx2,y+10,1,h-20);
    S.fillStyle="rgba("+cols[c]+","+(off?0.3:0.6)+")";S.fillRect(cx2+6,y+13,colw-14,3);
    var n=off?2:(2+((c+(st==="working"?Math.floor(t):0))%3));
    for(var k=0;k<n;k++){var cc=cols[(c+k)%4];S.fillStyle="rgba("+cc+","+(off?0.18:0.48)+")";S.fillRect(cx2+6,y+22+k*15,colw-14,11);S.fillStyle="rgba(0,0,0,0.3)";S.fillRect(cx2+6,y+22+k*15,colw-14,1);}
  }
}
function radar(t,st){
  var cx2=690,cy2=248,r=34,off=st==="offline";
  S.fillStyle="#0a1016";S.beginPath();S.arc(cx2,cy2,r,0,7);S.fill();
  S.strokeStyle="rgba(95,206,155,0.25)";S.lineWidth=1;for(var i=1;i<=3;i++){S.beginPath();S.arc(cx2,cy2,r*i/3,0,7);S.stroke();}
  S.beginPath();S.moveTo(cx2-r,cy2);S.lineTo(cx2+r,cy2);S.moveTo(cx2,cy2-r);S.lineTo(cx2,cy2+r);S.stroke();
  if(!off){var a=t*1.5;emit(function(c){c.save();c.globalCompositeOperation="lighter";
    c.fillStyle="rgba(95,206,155,0.18)";c.beginPath();c.moveTo(cx2,cy2);c.arc(cx2,cy2,r,a-0.5,a);c.closePath();c.fill();
    c.strokeStyle="rgba(120,240,180,0.7)";c.lineWidth=1.5;c.beginPath();c.moveTo(cx2,cy2);c.lineTo(cx2+Math.cos(a)*r,cy2+Math.sin(a)*r);c.stroke();
    [[0.5,1.2],[0.72,2.8],[0.4,4.6]].forEach(function(b){var bx=cx2+Math.cos(b[1])*r*b[0],by=cy2+Math.sin(b[1])*r*b[0];c.fillStyle="rgba(120,240,180,"+(0.35+0.4*Math.sin(t*3+b[1]))+")";c.fillRect(bx-1,by-1,2,2);});c.restore();});}
  S.strokeStyle="#2a3038";S.lineWidth=2;S.beginPath();S.arc(cx2,cy2,r,0,7);S.stroke();
}
function switchboard(t,st){
  var x=740,y=222,w=54,h=42,off=st==="offline";
  plate(S,[[x,y],[x+w,y],[x+w,y+h],[x,y+h]],"#1a2230","#0c1018","#2a3648");
  for(var r=0;r<3;r++)for(var c=0;c<5;c++){var on=!off&&((r*5+c+Math.floor(t*2))%3===0);S.fillStyle=on?"rgba(95,206,155,0.9)":"#22303e";S.fillRect(x+6+c*9,y+7+r*11,5,5);if(on){G.fillStyle="rgba(95,206,155,0.7)";G.fillRect(x+6+c*9,y+7+r*11,5,5);}}
}
function mapConsole(t,st){
  var x=372,y=560,w=204,off=st==="offline";
  plate(S,[[x,y+6],[x+w,y+6],[x+w,y+18],[x,y+18]],"#26303e","#121a24","#33404f");
  S.fillStyle="#0d1119";S.fillRect(x+12,y+18,8,28);S.fillRect(x+w-20,y+18,8,28);
  S.fillStyle="#0a1622";S.fillRect(x+16,y-6,w-32,14);
  S.strokeStyle="rgba(70,110,150,0.3)";S.lineWidth=1;for(var gx=x+20;gx<x+w-16;gx+=16){S.beginPath();S.moveTo(gx,y-6);S.lineTo(gx,y+8);S.stroke();}
  if(!off)emit(function(c){c.save();c.globalCompositeOperation="lighter";var g6=c.createRadialGradient(x+w/2,y+1,2,x+w/2,y+1,70);g6.addColorStop(0,"rgba(90,150,220,0.15)");g6.addColorStop(1,"rgba(90,150,220,0)");c.fillStyle=g6;c.fillRect(x,y-14,w,30);
    for(var b=0;b<5;b++){var bx=x+26+b*((w-52)/4);c.fillStyle="rgba(120,190,255,"+(0.4+0.4*Math.sin(t*3+b))+")";c.fillRect(bx,y-2+((b%2)*4),2,2);}c.restore();});
}
function phoneBank(x){var y=612-30;plate(S,[[x,y],[x+40,y],[x+40,y+30],[x,y+30]],"#1a2230","#0c1018","#2a3648");for(var i=0;i<2;i++){S.fillStyle="#0e1620";S.fillRect(x+5+i*20,y+5,14,10);S.fillStyle="#3a4656";S.fillRect(x+7+i*20,y+7,10,2);}contactShadow(x+20,612,40);}

/* ===================== GRID-CELL MINIATURE (god-view LOD, hi-detail) ===================== */
var REPOCOL=["#e0913d","#e6c34a","#a884ff","#3fb0e6","#7bc86a","#e0664a"];
function drawMini(t,mx,my,mw,mh){
  if(mx===undefined){mw=336;mh=252;mx=22;my=VH-mh-40;}
  var off=STATE==="offline",work=STATE==="working";
  var acc=off?"#ff5147":"#ff9a3c";
  X.save();X.textBaseline="alphabetic";
  // card + drop shadow
  X.fillStyle="rgba(0,0,0,0.6)";rr(X,mx-4,my-4,mw+8,mh+8,14);X.fill();
  X.fillStyle="#05080e";rr(X,mx,my,mw,mh,11);X.fill();
  // vendor bezel + RTS corner ticks
  X.lineWidth=2;X.strokeStyle=off?"rgba(255,81,71,"+(0.5+0.35*Math.abs(Math.sin(t*4)))+")":"rgba(255,154,60,0.6)";rr(X,mx+1,my+1,mw-2,mh-2,10);X.stroke();
  X.strokeStyle=acc;X.lineWidth=2;var T=12;
  [[mx+6,my+6,1,1],[mx+mw-6,my+6,-1,1],[mx+6,my+mh-6,1,-1],[mx+mw-6,my+mh-6,-1,-1]].forEach(function(k){X.beginPath();X.moveTo(k[0],k[1]+T*k[3]);X.lineTo(k[0],k[1]);X.lineTo(k[0]+T*k[2],k[1]);X.stroke();});
  // title bar
  X.fillStyle="rgba(255,154,60,0.06)";rr(X,mx+8,my+8,mw-16,24,5);X.fill();
  X.fillStyle=off?"#5a3030":"#ff9a3c";X.beginPath();X.arc(mx+22,my+20,4,0,7);X.fill();
  X.textBaseline="middle";X.fillStyle="#dbe6f2";X.font="700 12px ui-monospace,monospace";X.fillText(UNIT(),mx+34,my+21);
  var chip=work?[(ROOM==="builder"?"● BUILDING":ROOM==="reviewer"?"● REVIEWING":"● DISPATCH"),"#f7bd4e"]:off?["▲ SILENT","#ff5147"]:["● IDLE","#5fce9b"];
  X.font="700 10px ui-monospace,monospace";var cwd=X.measureText(chip[0]).width;
  X.fillStyle="rgba(0,0,0,0.5)";rr(X,mx+mw-cwd-26,my+11,cwd+16,18,5);X.fill();X.fillStyle=chip[1];X.fillText(chip[0],mx+mw-cwd-18,my+21);
  X.textBaseline="alphabetic";
  // ---- diorama viewport ----
  var dx0=mx+10,dy0=my+40,dW=mw-20,dH=mh-72,fY=dy0+dH*0.84;
  X.save();rr(X,dx0,dy0,dW,dH,6);X.clip();
  var wg=X.createLinearGradient(0,dy0,0,dy0+dH);wg.addColorStop(0,"#0a1019");wg.addColorStop(0.8,"#070c14");wg.addColorStop(1,"#03060c");X.fillStyle=wg;X.fillRect(dx0,dy0,dW,dH);
  X.fillStyle="#04070d";X.fillRect(dx0,fY,dW,dy0+dH-fY);X.fillStyle="rgba(0,0,0,0.5)";X.fillRect(dx0,fY,dW,2);
  // — curated, spacious: robot hero + one motivated light + role prop + separated holo —
  var warm=ROOM==="builder", LB=warm?"255,204,138":ROOM==="reviewer"?"150,196,245":"176,150,240", LH=warm?"255,214,150":ROOM==="reviewer"?"200,230,255":"214,196,255";
  var mrs=0.27,rcx=dx0+dW*0.36,rpx=rcx-260*mrs,rpy=fY-560*mrs;
  X.strokeStyle="rgba(30,44,64,0.22)";X.lineWidth=1;X.beginPath();X.moveTo(dx0,dy0+dH*0.46);X.lineTo(dx0+dW,dy0+dH*0.46);X.stroke();
  X.save();X.globalAlpha=0.07;X.fillStyle="#d9b23a";X.font="700 9px ui-monospace,monospace";X.fillText("SECTOR-7",dx0+dW*0.5,dy0+16);X.restore();
  // role prop (far left): fabricator / diff-screen / kanban
  if(ROOM==="builder"){
    var fx=dx0+12,fw=26,ft=fY-82,fgr=X.createLinearGradient(0,ft,0,fY);fgr.addColorStop(0,"#161d29");fgr.addColorStop(1,"#0a0f16");X.fillStyle=fgr;X.fillRect(fx,ft,fw,fY-ft);
    X.fillStyle="rgba(201,162,39,0.42)";X.fillRect(fx+3,ft+3,fw-6,3);
    X.fillStyle="#04070c";X.fillRect(fx+4,ft+10,fw-8,52);
    if(!off){X.globalCompositeOperation="lighter";var fg=X.createRadialGradient(fx+fw/2,fY-26,2,fx+fw/2,fY-26,22);fg.addColorStop(0,"rgba(255,160,70,"+(work?0.42:0.22)+")");fg.addColorStop(1,"rgba(255,160,70,0)");X.fillStyle=fg;X.fillRect(fx-6,ft,fw+12,fY-ft);X.globalCompositeOperation="source-over";X.fillStyle=work?"rgba(255,180,90,0.8)":"rgba(255,150,60,0.4)";X.fillRect(fx+fw/2-4,fY-38,8,24);}
    X.fillStyle=off?"#ff5147":"#5fce9b";X.fillRect(fx+fw-6,ft+6,3,3);
  } else if(ROOM==="reviewer"){
    var sx=dx0+11,sy=fY-80,sw=30,sh=66,scr=off?0:t*(work?18:6);
    X.fillStyle="#0c1220";X.fillRect(sx,sy,sw,sh);X.fillStyle="#07121e";X.fillRect(sx+3,sy+3,sw-6,sh-6);
    for(var l=0;l<11;l++){var ly2=sy+5+((l*7+scr)%(sh-9));var kk=l%3,c2=kk===0?"90,200,120":kk===1?"210,90,90":"70,110,150";X.fillStyle="rgba("+c2+","+(off?0.12:0.52)+")";X.fillRect(sx+5,ly2,4+((l*13)%18),1.5);}
    if(!off){X.globalCompositeOperation="lighter";var sg=X.createRadialGradient(sx+sw/2,sy+sh/2,2,sx+sw/2,sy+sh/2,28);sg.addColorStop(0,"rgba(90,160,220,0.14)");sg.addColorStop(1,"rgba(90,160,220,0)");X.fillStyle=sg;X.fillRect(sx-8,sy-8,sw+16,sh+16);X.globalCompositeOperation="source-over";}
    X.fillStyle=off?"#ff5147":"#5fce9b";X.fillRect(sx+sw-6,sy+sh-6,3,3);
  } else {
    var bx=dx0+11,by=fY-78,bw=32,bh=64;X.fillStyle="#20262e";X.fillRect(bx,by,bw,bh);X.fillStyle="#2b3138";X.fillRect(bx+2,by+2,bw-4,bh-4);
    var kc=["247,189,78","92,180,255","201,139,255"];
    for(var cc3=0;cc3<3;cc3++){var kx=bx+3+cc3*10;X.fillStyle="rgba("+kc[cc3]+","+(off?0.3:0.6)+")";X.fillRect(kx,by+4,8,2);for(var kk3=0;kk3<3;kk3++){X.fillStyle="rgba("+kc[(cc3+kk3)%3]+","+(off?0.2:0.55)+")";X.fillRect(kx,by+9+kk3*13,8,9);}}
    if(!off){X.globalCompositeOperation="lighter";var kg=X.createRadialGradient(bx+bw/2,by+bh/2,2,bx+bw/2,by+bh/2,28);kg.addColorStop(0,"rgba(150,120,220,0.12)");kg.addColorStop(1,"rgba(150,120,220,0)");X.fillStyle=kg;X.fillRect(bx-8,by-8,bw+16,bh+16);X.globalCompositeOperation="source-over";}
  }
  // overhead lamp (warm builder / cool reviewer) — wide soft apex for headroom
  var lampx=rcx;
  X.fillStyle="#141a24";X.fillRect(lampx-9,dy0+2,18,5);X.fillStyle="#20293a";X.fillRect(lampx-9,dy0+2,18,1);
  if(!off){
    X.globalCompositeOperation="lighter";
    X.fillStyle="rgba("+LH+",0.85)";X.fillRect(lampx-3,dy0+7,6,2);
    var cone=X.createLinearGradient(0,dy0+8,0,fY);cone.addColorStop(0,"rgba("+LB+","+(0.12*(work?1:0.82))+")");cone.addColorStop(1,"rgba("+LB+",0)");X.fillStyle=cone;X.beginPath();X.moveTo(lampx-12,dy0+8);X.lineTo(lampx+12,dy0+8);X.lineTo(lampx+54,fY);X.lineTo(lampx-54,fY);X.closePath();X.fill();
    var hb=X.createRadialGradient(lampx,dy0+9,1,lampx,dy0+9,26);hb.addColorStop(0,"rgba("+LH+",0.26)");hb.addColorStop(1,"rgba("+LH+",0)");X.fillStyle=hb;X.beginPath();X.arc(lampx,dy0+9,26,0,7);X.fill();
    var pool=X.createRadialGradient(lampx,fY,2,lampx,fY,48);pool.addColorStop(0,"rgba("+LB+",0.4)");pool.addColorStop(1,"rgba("+LB+",0)");X.fillStyle=pool;X.beginPath();X.ellipse(lampx,fY+2,48,8,0,0,7);X.fill();
    X.globalCompositeOperation="source-over";
  } else {
    X.globalCompositeOperation="lighter";var rp=0.15+0.12*Math.abs(Math.sin(t*4));var rw2=X.createRadialGradient(lampx,dy0+dH*0.34,3,lampx,dy0+dH*0.34,dW*0.5);rw2.addColorStop(0,"rgba(255,60,50,"+rp+")");rw2.addColorStop(1,"rgba(255,60,50,0)");X.fillStyle=rw2;X.fillRect(dx0,dy0,dW,dH);X.globalCompositeOperation="source-over";
  }
  // ROBOT hero
  X.imageSmoothingEnabled=true;
  X.drawImage(robo,rpx,rpy,RW*mrs,RH*mrs);
  X.globalCompositeOperation="lighter";X.globalAlpha=off?0.5:0.9;X.drawImage(rrim,rpx,rpy,RW*mrs,RH*mrs);
  X.globalAlpha=0.5;X.filter="blur(2px)";X.drawImage(remit,rpx,rpy,RW*mrs,RH*mrs);X.filter="none";X.globalAlpha=1;X.globalCompositeOperation="source-over";
  // working weld arc at the hand (was missing → looked broken)
  if(work){var A0=ROOM==="builder"?"214,234,255":ROOM==="reviewer"?"180,224,255":"226,190,255",A1=ROOM==="builder"?"120,190,255":ROOM==="reviewer"?"90,180,255":"180,120,255";
    var mhx=rpx+lastHand.x*mrs,mhy=rpy+lastHand.y*mrs,fk=0.5+0.5*Math.sin(t*30);X.save();X.globalCompositeOperation="lighter";var ag=X.createRadialGradient(mhx,mhy,0.5,mhx,mhy,8);ag.addColorStop(0,"rgba("+A0+","+(0.7*fk+0.25)+")");ag.addColorStop(0.4,"rgba("+A1+","+(0.4*fk)+")");ag.addColorStop(1,"rgba("+A1+",0)");X.fillStyle=ag;X.beginPath();X.arc(mhx,mhy,8,0,7);X.fill();X.fillStyle="rgba(255,255,255,"+(0.6*fk+0.2)+")";X.fillRect(mhx-0.8,mhy-0.8,1.7,1.7);
    if(ROOM==="builder")for(var sp=0;sp<3;sp++){var sa=(Math.sin(t*22+sp*2.1)+1)/2;X.fillStyle="rgba(255,200,120,"+(0.5*sa)+")";X.fillRect(mhx+(sp-1)*1.6,mhy+2+sa*6,1,1);}
    if(ROOM!=="builder"){ // tiny working screen (a smaller, simpler version of the big holo)
      X.globalCompositeOperation="source-over";var C=ROOM==="reviewer"?"120,205,255":"201,139,255",pw=19,ph=14,pxp=mhx-2,pyp=mhy-ph-3;
      X.fillStyle="rgba("+C+",0.10)";rr(X,pxp,pyp,pw,ph,2);X.fill();X.strokeStyle="rgba("+C+",0.85)";X.lineWidth=1;rr(X,pxp,pyp,pw,ph,2);X.stroke();
      if(ROOM==="reviewer"){for(var l3=0;l3<3;l3++){var dc=l3===0?"90,210,130":l3===1?"230,100,100":"90,150,210";X.fillStyle="rgba("+dc+",0.85)";X.fillRect(pxp+3,pyp+3+l3*3,6+l3*3,1);}X.fillStyle="rgba(200,240,255,0.6)";X.fillRect(pxp+2,pyp+2+((t*20)%(ph-3)),pw-4,1);}
      else{for(var b3=0;b3<3;b3++){X.fillStyle="rgba(201,139,255,0.75)";X.fillRect(pxp+4+b3*5,pyp+3,2,ph-6);if((b3+Math.floor(t*2))%2===0){X.fillStyle="rgba(247,189,78,0.9)";X.fillRect(pxp+3+b3*5,pyp+3+((t*15+b3*3)%(ph-7)),4,2);}}}
    }
    X.restore();}
  if(off){X.fillStyle="rgba(255,60,50,"+(0.6+0.4*Math.abs(Math.sin(t*4)))+")";X.font="700 12px ui-monospace,monospace";X.textAlign="center";X.fillText("!",rcx,rpy+34);X.textAlign="left";}
  // thin desk in front
  X.fillStyle="#1a2230";X.fillRect(rcx-22,fY-6,50,6);X.fillStyle="#0d1119";X.fillRect(rcx-18,fY,4,7);X.fillRect(rcx+20,fY,4,7);
  // compact holo panel (right, well separated) — state + queue
  var hx=dx0+dW*0.60,hy=dy0+dH*0.28,hw=dW*0.33,hh=dH*0.40,C0=off?[255,74,66]:[95,214,255],fl=off?(Math.random()<0.2?0.4:0.9):0.95,cs=C0[0]+","+C0[1]+","+C0[2];
  X.save();X.globalCompositeOperation="lighter";X.strokeStyle="rgba("+cs+",0.13)";X.lineWidth=1;X.beginPath();X.moveTo(rcx+14,fY-16);X.lineTo(hx+8,hy+hh);X.stroke();X.restore();
  X.save();X.globalAlpha=fl;
  X.fillStyle="rgba("+cs+",0.05)";rr(X,hx,hy,hw,hh,4);X.fill();
  X.strokeStyle="rgba("+cs+",0.75)";X.lineWidth=1;rr(X,hx,hy,hw,hh,4);X.stroke();
  X.lineWidth=1.5;[[hx,hy,1,1],[hx+hw,hy,-1,1],[hx,hy+hh,1,-1],[hx+hw,hy+hh,-1,-1]].forEach(function(k){X.beginPath();X.moveTo(k[0],k[1]+7*k[3]);X.lineTo(k[0],k[1]);X.lineTo(k[0]+7*k[2],k[1]);X.stroke();});
  X.fillStyle="rgba("+cs+",0.9)";X.font="700 8px ui-monospace,monospace";X.fillText(off?"◇ SIGNAL LOST":"◆ DIAGNOSTIC",hx+7,hy+13);
  X.font="8px ui-monospace,monospace";X.fillStyle="rgba("+cs+",0.62)";
  X.fillText(off?"CRON  SILENT":(work?(ROOM==="builder"?"STATE BUILD":ROOM==="reviewer"?"STATE REVIEW":"STATE TRIAGE"):"STATE STANDBY"),hx+7,hy+29);
  X.fillText(off?"LINK  ———":"QUEUE q"+dataOf(BOX,ROOM).queue.length,hx+7,hy+42);
  X.strokeStyle="rgba("+cs+",0.8)";X.lineWidth=1;X.beginPath();for(var wxp=0;wxp<hw-14;wxp+=2){var amp=off?1.5:(work?4:2),wyp=hy+hh-8+Math.sin(wxp*0.4+t*(work?6:2.5))*amp;if(wxp===0)X.moveTo(hx+7+wxp,wyp);else X.lineTo(hx+7+wxp,wyp);}X.stroke();
  X.restore();
  // screen feel: faint scanlines + inner vignette
  X.globalAlpha=0.045;X.fillStyle="#000";for(var sl=dy0;sl<dy0+dH;sl+=3)X.fillRect(dx0,sl,dW,1);X.globalAlpha=1;
  var iv=X.createRadialGradient(dx0+dW/2,dy0+dH/2,dH*0.2,dx0+dW/2,dy0+dH/2,dH*0.78);iv.addColorStop(0,"rgba(0,0,0,0)");iv.addColorStop(1,"rgba(0,0,0,0.5)");X.fillStyle=iv;X.fillRect(dx0,dy0,dW,dH);
  X.restore();X.restore();
}

/* ===================== GOD-VIEW FLOOR (scrollable fleet of cells) ===================== */
var VIEW="floor";
/* The page has two modes and decides between them at load, by asking the
   collector for a snapshot:

     served by `crew floor`  → /api/fleet answers → LIVE, real telemetry, real
                               operator controls (crew reads and drives every
                               box from the host over `box exec`)
     opened as a local file  → the fetch fails → DEMO, the placeholder fleet
                               below, controls shown but disabled

   That keeps the property the prototype was built on — one self-contained
   index.html you can just open — while making the served copy a real console.
   Nothing below is a fallback for missing live fields: a served page renders
   only what the boxes actually reported. */
var LIVE=false;
var ROSTER=[
  {agent:"claude",room:"triage",  state:"working"},
  {agent:"claude",room:"builder", state:"working"},
  {agent:"claude",room:"reviewer",state:"idle"},
  {agent:"codex", room:"builder", state:"working"},
  {agent:"codex", room:"reviewer",state:"working"},
  {agent:"grok",  room:"reviewer",state:"idle"},
  {agent:"kimi",  room:"reviewer",state:"offline"}
];
var CELLW=336, CELLH=252, GAPX=28, GAPY=26, MARGINL=44;
var floorCam=0, floorCamTarget=0, floorDrag=false, floorDragX=0, floorDragCam=0, floorMoved=false, floorMouse={x:-1,y:-1}, floorHits=[];
function floorTotalW(){var cols=Math.ceil(ROSTER.length/2);return MARGINL*2+cols*CELLW+(cols-1)*GAPX;}
function drawCell(t,x,y,w,h,unit){var sa=AGENT,sr=ROOM,ss=STATE,sl=lastHand,sb=BOX;AGENT=unit.agent;ROOM=unit.room;STATE=unit.state;BOX=UNITID(unit);var info=buildRobo(t,unit.state);lastHand=info.hand;drawMini(t,x,y,w,h);AGENT=sa;ROOM=sr;STATE=ss;lastHand=sl;BOX=sb;}
function drawFloor(t){
  X.setTransform(dpr,0,0,dpr,0,0);X.imageSmoothingEnabled=true;X.textAlign="left";X.globalAlpha=1;X.globalCompositeOperation="source-over";
  X.fillStyle="#03060d";X.fillRect(0,0,VW,VH);
  var vg=X.createRadialGradient(VW/2,VH*0.36,VH*0.15,VW/2,VH*0.5,VH);vg.addColorStop(0,"rgba(20,32,52,0.22)");vg.addColorStop(1,"rgba(0,0,0,0)");X.fillStyle=vg;X.fillRect(0,0,VW,VH);
  X.strokeStyle="rgba(40,60,90,0.05)";X.lineWidth=1;for(var gx=0;gx<VW;gx+=48){X.beginPath();X.moveTo(gx,0);X.lineTo(gx,VH);X.stroke();}for(var gy=0;gy<VH;gy+=48){X.beginPath();X.moveTo(0,gy);X.lineTo(VW,gy);X.stroke();}
  var camMax=Math.max(0,floorTotalW()-VW);
  if(!floorDrag)floorCam+=(floorCamTarget-floorCam)*0.18;
  floorCam=Math.max(0,Math.min(floorCam,camMax));floorCamTarget=Math.max(0,Math.min(floorCamTarget,camMax));
  var topY=Math.max(70,64+((VH-222)-(2*CELLH+GAPY))/2);
  floorHits.length=0;
  for(var i=0;i<ROSTER.length;i++){var col=Math.floor(i/2),row=i%2;var cx=MARGINL-floorCam+col*(CELLW+GAPX);var cy=topY+row*(CELLH+GAPY);
    if(cx>-CELLW-60&&cx<VW+60){
      var u=ROSTER[i],match=(floorFilter.state==="all"||u.state===floorFilter.state)&&(floorFilter.role==="all"||u.room===floorFilter.role);
      drawCell(t,cx,cy,CELLW,CELLH,u);
      if(!match){X.fillStyle="rgba(3,6,13,0.76)";rr(X,cx,cy,CELLW,CELLH,11);X.fill();}
      /* A STUCK or UNREACHABLE unit must be visible from the god-view. Both
         wear an ordinary state otherwise — stuck reads "working", and a box
         that fails its ping keeps whatever the last evidence poll concluded —
         so the grid showed a calm fleet in exactly the two situations an
         operator is scanning it for. Drawn after the filter scrim, so a
         filtered-out unit does not shout through it. */
      if(match)drawAlertBadge(cx,cy,u);
      var hov=(floorMouse.x>=cx&&floorMouse.x<=cx+CELLW&&floorMouse.y>=cy&&floorMouse.y<=cy+CELLH);
      if(hov&&match){X.save();X.strokeStyle="rgba(120,205,255,0.85)";X.lineWidth=2;rr(X,cx-2,cy-2,CELLW+4,CELLH+4,13);X.stroke();X.restore();}
      floorHits.push({x:cx,y:cy,i:i,match:match});
    }}
  if(camMax>0){var tw=Math.max(40,VW*(VW/floorTotalW())),tx=(floorCam/camMax)*(VW-tw),sby=VH-162;X.fillStyle="rgba(255,255,255,0.05)";X.fillRect(0,sby,VW,3);X.fillStyle="rgba(120,200,255,0.5)";X.fillRect(tx,sby,tw,3);}
  var vg2=X.createRadialGradient(VW/2,VH/2,VH*0.42,VW/2,VH/2,VH*0.95);vg2.addColorStop(0,"rgba(0,0,0,0)");vg2.addColorStop(1,"rgba(0,0,0,0.5)");X.fillStyle=vg2;X.fillRect(0,0,VW,VH);
}
/* alertOf UNIT — the one word this unit needs shouted on the grid, or "".
   Order is severity, not alphabetical: a box that has stopped answering pings
   is a worse fact than a stuck lock, and a stuck lock is worse than a dead
   credential, because each one makes the next impossible to act on. */
function alertOf(u){
  if(!LIVE)return "";
  var d=dataOf(UNITID(u),u.room);
  if(d.ping&&!d.ping.ok&&d.ping.fails>=PING_FAILS_SHOWN)return "UNREACHABLE";
  if(d.lock&&d.lock.stuck)return "STUCK";
  if(d.authfail&&d.authfail.length)return "AUTH";
  return "";
}
var PING_FAILS_SHOWN=3;
function drawAlertBadge(cx,cy,u){
  var a=alertOf(u);if(!a)return;
  X.save();
  X.font="700 9px ui-monospace,monospace";
  var w=X.measureText(a).width+12,h=15,bx=cx+CELLW-w-9,by=cy+9;
  X.fillStyle="rgba(255,81,71,0.92)";rr(X,bx,by,w,h,4);X.fill();
  /* Pulse, because these two states are otherwise indistinguishable from a
     calm cell at a glance across a wide grid. */
  X.globalAlpha=0.35+0.35*Math.sin(t2()/260);
  X.strokeStyle="#ff5147";X.lineWidth=2;rr(X,bx-2,by-2,w+4,h+4,6);X.stroke();
  X.globalAlpha=1;
  X.fillStyle="#0b0f16";X.textAlign="center";X.textBaseline="middle";
  X.fillText(a,bx+w/2,by+h/2+0.5);
  X.restore();X.textAlign="left";X.textBaseline="alphabetic";
}
function t2(){return Date.now();}
function drawFloorHeader(t){
  X.textBaseline="alphabetic";X.textAlign="left";
  X.font="700 15px ui-monospace,monospace";X.fillStyle="#c7d4e4";X.fillText("FLEET FLOOR",26,36);
  X.font="11px ui-monospace,monospace";X.fillStyle="#5fd6ff";X.fillText("heavy-duty/crew · god-view",132,36);
  X.font="10px ui-monospace,monospace";X.fillStyle="#46566a";X.fillText("scroll horizontally · click a unit to zoom in",26,54);
  var w=0,idl=0,offc=0;ROSTER.forEach(function(u){if(u.state==="working")w++;else if(u.state==="offline")offc++;else idl++;});
  var stat=[[offc+" SILENT","#ff5147"],[idl+" IDLE","#5fce9b"],[w+" WORKING","#f7bd4e"]];
  /* Prepended so it reads leftmost, ahead of the ordinary counts, and only
     when non-zero: a permanent "0 ALERT" is furniture. These units are ALSO
     counted as working or idle above — that is correct, they are, and the
     point of this counter is that the state they are in is not the whole
     story. */
  var alerts=LIVE?ROSTER.filter(function(u){return alertOf(u)!=="";}).length:0;
  if(alerts)stat.unshift([alerts+" ALERT","#ff5147"]);
  X.textAlign="right";X.font="700 11px ui-monospace,monospace";var sxp=VW-26;
  stat.forEach(function(s){X.fillStyle=s[1];X.fillText("● "+s[0],sxp,36);sxp-=X.measureText("● "+s[0]).width+20;});
  X.fillStyle="#46566a";X.font="10px ui-monospace,monospace";X.fillText(ROSTER.length+" UNITS",VW-26,54);
  X.textAlign="left";
}
function syncToggles(){
  var un=document.getElementById("un");if(!un)return;
  [].forEach.call(un.querySelectorAll("button"),function(b){b.classList.toggle("on",b.dataset.a===AGENT);});
  [].forEach.call(document.getElementById("rm").querySelectorAll("button"),function(b){b.classList.toggle("on",b.dataset.r===ROOM);});
  [].forEach.call(document.getElementById("stg").querySelectorAll("button"),function(b){b.className=(b.dataset.s===STATE?"on "+(STATE==="working"?"w":STATE==="offline"?"o":""):"");});
}
function focusUnit(i){var u=ROSTER[i];AGENT=u.agent;ROOM=u.room;STATE=u.state;BOX=UNITID(u);VIEW="room";syncToggles();refreshChrome();document.body.className="room";populateDash();}
function toFloor(){VIEW="floor";document.body.className="floor";buildOps();}

/* ---- fleet data + command-center HUD ---- */
var VCOL={claude:"#ff9a3c",codex:"#37d4a6",grok:"#b07cff",kimi:"#ff72b6"};
var REPONAMES=["ceremony","cast","box","rig","incubator","crew"];
var REPOC={ceremony:"#e0913d",cast:"#3fb0e6",box:"#7bc86a",rig:"#e0664a",incubator:"#a884ff",crew:"#e6c34a"};
var dataCache={}, floorFilter={state:"all",role:"all"};
function VENDORCOL(a){return VCOL[a]||"#8aa0b8";}
function hexA(h,a){h=h.replace("#","");return "rgba("+parseInt(h.substr(0,2),16)+","+parseInt(h.substr(2,2),16)+","+parseInt(h.substr(4,2),16)+","+a+")";}
function pad2(n){return (n<10?"0":"")+n;}
function ri2(a,b){return a+Math.floor(Math.random()*(b-a+1));}
function kindOf(room){return room==="builder"?"build":room==="reviewer"?"review":"triage";}
function outcomeFor(k){return k==="build"?["opened PR","pushed fixups","needs-human","resumed"][ri2(0,3)]:k==="review"?["approved","changes-requested","commented"][ri2(0,2)]:["labeled ready","routed to builder","marked blocked","ruling posted"][ri2(0,3)];}
function fmtDur(s){s=Math.max(0,Math.floor(s));var h=Math.floor(s/3600),m=Math.floor((s%3600)/60),ss=s%60;return h?(h+"h "+pad2(m)+"m"):(m?(m+"m "+pad2(ss)+"s"):(ss+"s"));}
function genData(room){var kind=kindOf(room),qn=ri2(2,6),q=[];for(var k=0;k<qn;k++)q.push({repo:REPONAMES[ri2(0,5)],key:ri2(11,148)});
  var sess=[],ago=ri2(1,5),cap=kind==="triage"?2400:7200;for(var s=0;s<11;s++){var rc=Math.random()<0.12?1:0;sess.push({ago:ago,kind:kind,rc:rc,dur:ri2(45,cap),out:rc?"aborted (budget)":outcomeFor(kind)});ago+=ri2(4,11);}
  var durs=sess.map(function(x){return x.dur;}),ok=sess.filter(function(x){return !x.rc;}).length;
  var spark=[];for(var sp=0;sp<22;sp++)spark.push(0.14+Math.random()*0.86);
  var nowS=Math.floor(Date.now()/1000),cur={key:(kind==="triage"?"board":REPONAMES[ri2(0,5)]+"#"+ri2(11,148)),start:nowS-ri2(20,Math.min(cap,5200))};
  return {kind:kind,queue:q,sessions:sess,up:{h:ri2(1,71),m:ri2(0,59)},repo:q[0]?q[0].repo:"crew",spark:spark,
    longest:Math.max.apply(null,durs),avg:Math.round(durs.reduce(function(a,b){return a+b;},0)/durs.length),success:Math.round(100*ok/sess.length),today:ri2(8,46),cur:cur};}
function fleetMetric(){var lb=0,lr=0,lt=0,all=[];ROSTER.forEach(function(u){var d=dataOf(UNITID(u),u.room);all=all.concat(d.sessions.map(function(s){return s.dur;}));if(u.room==="builder")lb=Math.max(lb,d.longest);else if(u.room==="reviewer")lr=Math.max(lr,d.longest);else lt=Math.max(lt,d.longest);});return {build:lb,review:lr,triage:lt,avg:all.length?Math.round(all.reduce(function(a,b){return a+b;},0)/all.length):0};}
function dataOf(box,room){if(!dataCache[box])dataCache[box]=LIVE?emptyData(room||ROOM):genData(room||ROOM);return dataCache[box];}
function emptyData(room){return {kind:kindOf(room),queue:[],sessions:[],up:{h:0,m:0},repo:"",spark:[],longest:0,avg:0,success:0,today:0,cur:null,live:true,gh:"unknown",vendor:"unknown",engine:"",cron:{ok:false,last:null,age:null},note:"",paused:false,box:"",logs:[],ping:null,lock:{held:null,stuck:false},authfail:[]};}

/* ===================== LIVE MODE (collector at /api, see server/floor.py) =====================
   The collector polls every box from the operator host over `box exec` and
   serves the result here; operator actions POST back and are applied the same
   way. The boxes still initiate nothing and run nothing extra — the host's
   existing control channel does both halves. */
var LIVEMETA=null, POLL_MS=15000, seenSess={};
/* When the snapshot on screen was received. The stuck timer counts from the
   lock age the box reported PLUS the time since we heard it, so the readout
   keeps advancing between polls instead of freezing at a stale number and
   then jumping a minute. */
var LASTPOLL=Date.now();
/* Absolute, credential-free. An operator who bookmarks the page as
   http://user:pass@host:port/ leaves credentials in the document URL, and a
   relative fetch inherits them — which the browser then refuses to construct a
   Request from, silently stranding the page in DEMO. location.origin drops
   them. */
/* Live repo strings are FULL owner/repo names — repos.txt holds
   "heavy-duty/ceremony", and the duty log's `attention: $repo#$num` carries the
   owner too. Prefixing the org unconditionally produced
   github.com/heavy-duty/heavy-duty%2Fcrew on every live unit. Encode per path
   segment so a slash stays a slash. */
function repoURL(repo){
  var parts=String(repo).split("/").filter(Boolean).map(encodeURIComponent);
  if(parts.length<2)parts=["heavy-duty"].concat(parts);
  return "https://github.com/"+parts.join("/");
}
function apiURL(path){return (location.origin&&location.origin!=="null"?location.origin:"")+path;}
function api(path,opts){return fetch(apiURL(path),opts||{}).then(function(r){
  if(r.status===401){throw new Error("unauthorized");}
  /* A partly-failed fleet action answers 500 with the per-box detail in the
     body. Throwing on !ok would discard exactly the part worth showing and
     leave the operator with a bare status code. */
  return r.json().then(function(j){
    if(!r.ok&&!(j&&j.results))throw new Error((j&&j.error)||("HTTP "+r.status));
    return j;
  },function(){throw new Error("HTTP "+r.status);});});}
/* Server unit -> the record every panel already reads, so nothing downstream
   has to know which mode it is in. */
function liveData(u){
  var d=emptyData(u.room);
  d.box=u.box;d.queue=u.queue||[];d.sessions=u.sessions||[];d.up=u.up||{h:0,m:0};
  d.repo=u.repo||"";d.spark=(u.spark&&u.spark.length?u.spark:[]);d.longest=u.longest||0;
  d.avg=u.avg||0;d.success=u.success||0;d.today=u.today||0;d.cur=u.cur||null;
  d.gh=u.gh;d.vendor=u.vendor;d.engine=u.engine||"";d.cron=u.cron||d.cron;
  /* The ping tier and the flow-reported credential state. Defaulted rather
     than assigned straight through: a collector older than these fields, or a
     unit built from the error path, must render as "not known" and never as a
     missing-property crash mid-draw. */
  d.ping=u.ping||null;d.lock=u.lock||{held:null,stuck:false};
  d.authfail=u.authfail||[];
  d.note=u.note||"";d.paused=!!u.paused;d.logs=u.logs||[];d.repos=u.repos||[];
  if(d.cur&&d.cur.kind)d.kind=d.cur.kind;
  return d;
}
function applyFleet(snap){
  if(!snap||!snap.units)return;
  if(!snap.units.length){
    /* A well-formed answer with no boxes is a FACT, not a failed poll. Falling
       back to DEMO here would show an operator a floor full of plausible
       placeholder boxes while a real collector sat behind it reporting an
       empty roster. Once live, though, an empty poll keeps the last snapshot
       rather than blanking a fleet that was there a second ago. */
    if(!LIVE){LIVE=true;LIVEMETA=snap;ROSTER=[];dataCache={};goLive();
      buildTiles();buildOps();
      setStatus("collector reports an empty fleet — check the resolved fleet roster",true);}
    return;
  }
  LIVEMETA=snap;
  var first=!LIVE;LIVE=true;LASTPOLL=Date.now();
  var roster=[],cache={};
  snap.units.forEach(function(u){
    /* working means "a session is open"; without one the cell has nothing to
       count up from, so it is standby however the probe was labelled. */
    var st=(u.state==="working"&&!u.cur)?"idle":u.state;
    roster.push({agent:u.agent,room:u.room,state:st,box:u.box,note:u.note||""});
    cache[u.box]=liveData(u);
  });
  ROSTER=roster;dataCache=cache;
  if(first)goLive();
  /* Keep the operator's current focus pinned across polls rather than snapping
     the view back to the floor every 15 seconds. */
  var me=ROSTER.filter(function(u){return UNITID(u)===BOX;})[0];
  if(me){STATE=me.state;AGENT=me.agent;ROOM=me.room;}
  else if(VIEW==="room"){
    /* The roster is re-read every poll, so the box an operator is standing in
       can be removed, renamed, or `crew new`-ed away underneath them. Pinning
       the focus across polls is deliberate, but pinning it to something that
       no longer exists renders a plausible, quiet, entirely fictional console
       — the phantom-box twin of a frozen fleet that looks calm. Say so and go
       back to the floor, which is the only view that is still true. */
    var gone=BOX;
    toFloor();
    setStatus(gone+" is no longer in the fleet — returned to the floor",true);
    return;
  }
  buildTiles();buildOps();syncToggles();refreshChrome();
  if(VIEW==="room")populateDash();
  liveTicker(snap);
}

/* Real duty.log events only: each poll emits the SESSION lines that are new
   since the last one, so the ticker is evidence rather than atmosphere. */
function liveTicker(snap){
  var s=document.getElementById("stream");if(!s)return;
  var fresh=[],next={},primed=seenSess.__primed;
  snap.units.forEach(function(u){
    (u.sessions||[]).slice(0,6).forEach(function(x){
      var id=u.box+"|"+x.kind+"|"+x.key+"|"+x.dur+"|"+x.out;
      next[id]=1;
      if(seenSess[id]||!primed)return;
      fresh.push({u:u,msg:"SESSION END kind="+x.kind+" key="+x.key+" rc="+x.rc+" outcome="+x.out,rc:x.rc,ago:x.ago});
    });
    if(u.cur){
      var cid=u.box+"|open|"+u.cur.kind+"|"+u.cur.key+"|"+u.cur.start;
      next[cid]=1;
      if(!seenSess[cid]&&primed)fresh.push({u:u,msg:"SESSION START kind="+u.cur.kind+" key="+u.cur.key,rc:0});
    }
  });
  /* Carry only the ids still in this snapshot. duty.log is append-only, so an
     id that has aged out of the window cannot come back and be re-emitted —
     which keeps the dedup set bounded on a page left open for days. */
  next.__primed=1;seenSess=next;
  fresh.sort(function(a,b){return (b.ago||0)-(a.ago||0);});
  fresh.forEach(function(f){
    var el=document.createElement("div");el.className="l";
    var m=esc(f.msg);
    m=f.rc?m.replace(/rc=\d+/,'<span class="cr">rc='+f.rc+'</span>'):m.replace(/(outcome=.*)$/,'<span class="ok">$1</span>');
    el.innerHTML='<span class="tt">'+clockStr()+'</span><span class="u" style="color:'+VENDORCOL(f.u.agent)+'">'+esc(f.u.box)+'</span><span class="m">'+m+'</span>';
    s.appendChild(el);
  });
  while(s.childNodes.length>30)s.removeChild(s.firstChild);
  if(fresh.length)s.scrollTop=s.scrollHeight;
}
/* A live page whose collector has died keeps rendering the last snapshot, and
   a frozen fleet looks exactly like a calm one — the same trap the engine's
   own "silence = dead" rule exists to close, one level up. After two missed
   polls the page says so instead of quietly showing yesterday's news. */
var pollFails=0, STALE_AFTER=2;
function pollFleet(){
  /* Opened from disk there is nothing to poll, and asking anyway just prints a
     CORS failure in the console of a page that is working exactly as intended. */
  if(location.protocol==="file:")return;
  api("/api/fleet").then(function(snap){
    pollFails=0;setStale(false);applyFleet(snap);
  }).catch(function(e){
    if(String(e.message)==="unauthorized")return setStatus("unauthorized — reload and sign in",true);
    /* Never went live at all: no collector, so DEMO is the honest state and
       there is nothing stale about it. */
    if(!LIVE)return;
    if(++pollFails>=STALE_AFTER)setStale(true,e.message);
  });
}
function setStale(on,why){
  var badges=document.querySelectorAll(".demo-badge");
  [].forEach.call(badges,function(b){
    b.classList.toggle("stale",!!on);
    if(on){b.textContent="◈ STALE";b.title="The collector stopped answering — this is the last snapshot, not the current fleet.";}
    else if(LIVE){b.textContent="◈ LIVE";b.title="Live telemetry — every box polled from the operator host over 'box exec'.";}
  });
  if(on)setStatus("collector unreachable — frozen at "+((LIVEMETA&&LIVEMETA.generated)||"?")+(why?" ("+why+")":""),true);
}
function setStatus(msg,bad){
  var el=document.getElementById("livestat");if(!el)return;
  el.textContent=msg;el.style.color=bad?"#ff5147":"#5fce9b";
}
/* One-time flip of everything the DEMO build deliberately nailed shut. */
function goLive(){
  [].forEach.call(document.querySelectorAll(".demo-badge"),function(b){
    b.textContent="◈ LIVE";b.classList.add("live");
    b.title="Live telemetry — every box polled from the operator host over 'box exec'.";
  });
  ["g-start","g-stop","g-wake","a-pause","a-restart","c-send"].forEach(function(id){
    var e=document.getElementById(id);if(e){e.classList.remove("woff");e.title="";}
  });
  var cin=document.getElementById("c-in");
  if(cin){cin.disabled=false;cin.classList.remove("woff");cin.placeholder="Send a prompt to the agent…";}
  var s=document.getElementById("stream");if(s)s.innerHTML="";
}
/* Operator actions (#39). Every one is applied by the host with `box exec`,
   `box down` or `box start`; the reply carries per-box rc so a refused or
   failed action is reported instead of being animated as success. */
function cmd(action,extra){
  var body=Object.assign({action:action},extra||{});
  setStatus(action+"…",false);
  return api("/api/command",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(body)})
    .then(function(r){
      var bad=(r.results||[]).filter(function(x){return !x.ok;});
      /* Name the box that refused. On a fleet-wide action "start-all FAILED"
         alone tells the operator nothing about which box needs a look. */
      var why=bad.length?(bad[0].box+": "+bad[0].out+(bad.length>1?" (+"+(bad.length-1)+" more)":"")):(r.error||"?");
      setStatus(r.ok?action+" ok":action+" FAILED — "+why,!r.ok);
      pollFleet();
      return r;
    })
    .catch(function(e){setStatus(action+" failed: "+e.message,true);});
}
function esc(s){return String(s).replace(/[&<>]/g,function(c){return c==="&"?"&amp;":c==="<"?"&lt;":"&gt;";});}
function clockStr(){var d=new Date();return pad2(d.getUTCHours())+":"+pad2(d.getUTCMinutes())+":"+pad2(d.getUTCSeconds());}
function buildTiles(){var w=0,idl=0,o=0,q=0;ROSTER.forEach(function(u){if(u.state==="working")w++;else if(u.state==="offline")o++;else idl++;q+=dataOf(UNITID(u),u.room).queue.length;});
  function tl(n,l,c,al){return '<div class="tile'+(al?' alert':'')+'"><span class="n" style="color:'+c+'">'+n+'</span><span class="l">'+l+'</span></div>';}
  var el=document.getElementById("tiles");if(el)el.innerHTML=tl(ROSTER.length,"units","#c7d4e4")+tl(w,"working","#f7bd4e")+tl(idl,"idle","#5fce9b")+tl(o,"silent","#ff5147",o>0)+tl(q,"queued","#5fd6ff");}
function populateDash(){
  if(VIEW!=="room")return;
  /* The art-preview toggles can set any STATE; live data may disagree. Only
     claim a session is running when there is one to count. */
  var d=dataOf(BOX,ROOM),id=UNIT(),vc=VENDORCOL(AGENT),off=STATE==="offline",work=STATE==="working"&&!!(d.cur||!LIVE);
  var sc=off?"#ff5147":work?"#f7bd4e":"#5fce9b",sl=off?"SILENT":work?(d.kind==="build"?"BUILDING":d.kind==="review"?"REVIEWING":"DISPATCHING"):"STANDBY";
  document.getElementById("w-id").innerHTML='<div class="idc"><div class="av" style="background:'+hexA(vc,0.16)+';box-shadow:inset 0 0 0 1px '+hexA(vc,0.5)+';color:'+vc+'">'+AGENT[0].toUpperCase()+'</div><div><div class="nm">'+id+'</div><div class="rl">'+AGENT+' · '+ROOM+'</div><span class="pill" style="color:'+sc+';background:'+hexA(sc,0.14)+';box-shadow:inset 0 0 0 1px '+hexA(sc,0.4)+'">● '+sl+'</span></div></div><div class="spark" title="24h activity">'+(off?"":d.spark.map(function(v,i){return '<span style="height:'+Math.round(v*100)+'%;background:'+hexA(vc,i>=d.spark.length-4?0.95:0.42)+'"></span>';}).join(''))+'</div>';
  /* In LIVE mode every value here is what the box reported this poll; the
     DEMO strings it replaces were the placeholders #38 was filed about. */
  var vBox=off?"unreachable":"gh ✓ · box ✓", vCron=off?"SILENT":"≤2m ago", vRc=(off||!d.sessions.length)?"—":d.sessions[0].rc;
  if(LIVE){
    vBox=credGlyph("gh",d.gh)+" · "+credGlyph(AGENT,d.vendor);
    vCron=d.paused?"PAUSED":(d.cron.age===null||d.cron.age===undefined)?"no ticks yet":(d.cron.ok?fmtDur(d.cron.age)+" ago":"SILENT · "+fmtDur(d.cron.age));
    if(d.note&&!d.engine)vBox=esc(d.note);
  }
  document.getElementById("w-vitals").innerHTML='<div class="wt"><span class="dot"></span>VITALS</div><div class="kv">'
    +'<span class="k">Box</span><span class="v" style="color:'+(off?"#ff5147":credColour(d))+'">'+vBox+'</span>'
    /* Directly under Box, because it answers the same question on a much
       shorter clock: Box is what the last evidence poll concluded up to a
       minute ago, Heartbeat is whether the guest answered seconds ago. */
    +'<span class="k">Heartbeat</span><span class="v" id="v-ping" style="color:'+pingColour(d)+'">'+pingText(d)+'</span>'
    +'<span class="k">Uptime</span><span class="v">'+(off&&!LIVE?"—":(d.up.h+"h "+pad2(d.up.m)+"m"))+'</span>'
    +'<span class="k">Cron</span><span class="v" style="color:'+((off||d.paused)?"#ff5147":"#c7d4e4")+'">'+vCron+'</span>'
    +'<span class="k">Repo</span><span class="v">'+esc(d.repo||"—")+'</span>'
    +'<span class="k">Sessions today</span><span class="v">'+d.today+'</span>'
    +'<span class="k">Last rc</span><span class="v">'+vRc+'</span></div>';
  document.getElementById("w-queue").innerHTML='<div class="wt"><span class="dot"></span>WORK QUEUE · q'+d.queue.length+'</div><div class="qchips">'
    /* Live keys are whatever the duty modules logged — an issue number, but
       also "ready 2", "resume", "3 mention". Only number them when they are
       numbers. */
    +(d.queue.length?d.queue.map(function(q){return '<span class="qc" style="border-color:'+(REPOC[q.repo]||"#3a4a60")+'">'+esc(q.repo)+' '+(/^\d+$/.test(q.key)?"#":"")+esc(q.key)+'</span>';}).join(''):'<span style="color:#46566a;font-family:var(--mono);font-size:10px">— empty —</span>')+'</div>'
    +'<div class="wt" style="margin-top:16px"><span class="dot"></span>ACCESS</div><div class="access">'
    +ab("ac-repo","⎇ &nbsp;Open repo · "+esc(d.repo||"—"))+ab("ac-term","◱ &nbsp;Copy box shell command")
    +ab("ac-logs","▤ &nbsp;Raw session logs")+ab("ac-restart","↻ &nbsp;Restart box")
    +'<div style="display:flex;gap:6px"><button class="lbtn pw'+(LIVE?'':' woff')+'" data-pw="off"'+(LIVE?'':' title="'+CTL_TIP+'"')+' style="flex:1;text-align:center;'+(off?'opacity:.5':'color:#ff8a7c;border-color:#3a1c1c')+'">⏻ Power off</button><button class="lbtn pw'+(LIVE?'':' woff')+'" data-pw="on"'+(LIVE?'':' title="'+CTL_TIP+'"')+' style="flex:1;text-align:center;'+(off?'color:#5fce9b;border-color:#1c3a2a':'opacity:.5')+'">⭘ Power on</button></div></div>';
  var cs='<div class="wt"><span class="dot"></span>CURRENT SESSION</div><div class="cursess">';
  if(off)cs+='<div class="big" style="color:#ff5147">— SILENT —</div><div class="task">'+esc(LIVE&&d.note?d.note:"no active session · cron missed")+'</div>';
  /* STUCK outranks the running-session view even though a session IS running.
     That is the whole point: cron is ticking, duty.log is fresh, the box looks
     busy — and it has been holding the same lock for longer than two tick
     boundaries. Showing the elapsed timer alone reads as healthy progress.
     No progress bar here either; there is no progress to draw. */
  else if(LIVE&&d.lock&&d.lock.stuck)cs+='<div class="big" id="cur-el" style="color:#ff5147">'+fmtDur(d.lock.held)+'</div><div class="task" id="cur-stuck" style="color:#ff8a7c">STUCK · lock held '+fmtDur(d.lock.held)+(d.cur?' · '+esc(d.kind)+' '+esc(d.cur.key):'')+'</div>';
  else if(work)cs+='<div class="big" id="cur-el">'+fmtDur(Math.floor(Date.now()/1000)-d.cur.start)+'</div><div class="task">'+esc(d.kind)+' · '+esc(d.cur.key)+'</div><div class="pbar"><i></i></div>';
  else cs+='<div class="big" style="color:#5fce9b">STANDBY</div><div class="task">idle · awaiting next tick</div>';
  document.getElementById("w-current").innerHTML=cs+'</div>';
  var mk=d.kind==="build"?"Build":d.kind==="review"?"Review":"Triage";
  document.getElementById("w-metrics").innerHTML='<div class="wt"><span class="dot"></span>TIME METRICS</div><div class="mgrid">'
    +'<div class="mcell"><div class="mv">'+fmtDur(d.longest)+'</div><div class="ml">Longest '+mk+'</div></div>'
    +'<div class="mcell"><div class="mv">'+fmtDur(d.avg)+'</div><div class="ml">Avg session</div></div>'
    +'<div class="mcell"><div class="mv">'+d.today+'</div><div class="ml">Runs today</div></div>'
    +'<div class="mcell"><div class="mv" style="color:'+(d.success>85?"#5fce9b":"#f7bd4e")+'">'+d.success+'%</div><div class="ml">Success rc0</div></div></div>';
  var sh='<div class="wt"><span class="dot"></span>SESSION HISTORY</div><div class="feed" id="dfeed">';
  d.sessions.forEach(function(s){sh+='<div class="fev k-'+s.kind+'"><span class="ago">'+s.ago+'m</span><span class="kd">'+s.kind+'</span><span class="'+(s.rc?"cr":"ok")+'" style="flex:1;overflow:hidden;text-overflow:ellipsis">'+esc(s.out)+'</span><span style="color:#46566a">'+fmtDur(s.dur)+'</span></div>';});
  document.getElementById("w-sessions").innerHTML=sh+'</div>';
  document.getElementById("c-target").textContent="▸ MESSAGE "+id;
  var ci=document.getElementById("c-in");if(ci)ci.placeholder="Send a prompt to "+id+"…";
  /* Follows d.paused, not the working state: an idle but unpaused box was
     offering "Resume" while its click correctly sent `pause`. */
  document.getElementById("a-pause").textContent=(LIVE&&d.paused)||(!LIVE&&!work)?"▶ Resume":"⏸ Pause";
}
function updateCurrent(){if(VIEW!=="room"||STATE!=="working")return;var d=dataOf(BOX,ROOM);var el=document.getElementById("cur-el");if(!el)return;
  /* A stuck box is still STATE==="working" and may still have a d.cur, so
     without this branch the per-second tick overwrote the red held-duration
     with the session's own elapsed time — quietly restoring the healthy-
     looking readout the STUCK panel exists to replace. Keep counting, but
     count the thing that is wrong. */
  if(LIVE&&d.lock&&d.lock.stuck){el.textContent=fmtDur(d.lock.held+Math.floor((Date.now()-LASTPOLL)/1000));return;}
  if(!d.cur)return;el.textContent=fmtDur(Math.floor(Date.now()/1000)-d.cur.start);}
function mrow(k,v){return '<div class="mrow"><span class="mk">'+k+'</span><span class="mvv">'+v+'</span></div>';}
/* --- credential + heartbeat rendering -----------------------------------
   THREE credential states, not two. The probe stopped answering `ok` when it
   stopped testing credentials: it now reports what the duty engine last
   observed, and "no failure has been reported" is not the same claim as "I
   just checked and it works". Collapsing them back into a tick/cross here
   would put the lie straight back on screen — and rendering anything that is
   not the string "ok" as a cross (which this did) marked every healthy box
   as logged out the moment the vocabulary changed. */
function credGlyph(label,v){
  if(v==="flowing")return label+" ✓";
  if(v==="missing")return label+" ✗";
  /* stale: the engine is installed but not ticking, so nothing has been able
     to find out. Distinct from unknown (never installed) and emphatically
     distinct from ✓ — a disarmed box with a dead token used to render a tick
     here, which is the single most misleading thing this panel could say. */
  if(v==="stale")return label+" ~";
  return label+" ?";               /* unknown: no engine has run, so nothing is known */
}
function credColour(d){
  if(d.gh==="missing"||d.vendor==="missing")return "#ff5147";
  if(d.gh==="flowing"&&d.vendor==="flowing")return "#5fce9b";
  return "#f7bd4e";                /* stale or unknown: not established, not green */
}
/* The ping tier. `null` means this collector never reported one — an older
   floor.py, or a box it skipped because it is stopped — and must read as "—",
   never as a failure. */
function pingText(d){
  if(!LIVE)return "—";
  if(!d.ping)return "—";
  /* Stale outranks ok: the tier has not run recently enough for its last
     answer to be a claim about now, and showing "8ms · ok" from an arbitrarily
     old round is stale green on a liveness widget — the exact thing this tier
     was added to prevent. */
  if(d.ping.stale)return "stale · "+fmtDur(d.ping.age)+" old";
  if(d.ping.ok)return d.ping.ms+"ms · "+d.ping.age+"s ago";
  return "no answer · "+d.ping.fails+" missed";
}
function pingColour(d){
  if(!LIVE||!d.ping)return "#46566a";
  if(d.ping.stale)return "#f7bd4e";   /* amber: unknown, not green and not red */
  return d.ping.ok?"#5fce9b":"#ff5147";
}
/* Access-panel button: live ones are real, demo ones keep the .woff tooltip
   that says why they do nothing. */
function ab(id,label){return '<button class="lbtn'+(LIVE?'':' woff')+'" id="'+id+'"'+(LIVE?'':' title="'+CTL_TIP+'"')+'>'+label+'</button>';}
function buildOps(){var list=document.getElementById("opslist");if(!list)return;var working=ROSTER.filter(function(u){return u.state==="working"&&dataOf(UNITID(u),u.room).cur;});
  var cc=document.getElementById("ops-count");if(cc)cc.textContent="· "+working.length;
  list.innerHTML=working.length?working.map(function(u){var d=dataOf(UNITID(u),u.room),vc=VENDORCOL(u.agent),kc=u.room==="builder"?"#f7bd4e":u.room==="reviewer"?"#5cb4ff":"#c98bff";
    return '<div class="op"><span class="u" style="color:'+vc+'">'+esc(u.box||(u.agent+"-"+u.room))+'</span><span class="kd" style="color:'+kc+';background:'+hexA(kc,0.13)+'">'+esc(d.kind)+'</span><span class="tk">'+esc(d.cur.key)+'</span><span class="el" data-s="'+d.cur.start+'">'+fmtDur(Math.floor(Date.now()/1000)-d.cur.start)+'</span></div>';}).join(''):'<div style="color:#46566a;font-family:var(--mono);font-size:11px;padding:4px 0">— no active sessions —</div>';
  var fm=fleetMetric(),mr=document.getElementById("metrows");if(mr)mr.innerHTML=mrow("Longest build",fmtDur(fm.build))+mrow("Longest review",fmtDur(fm.review))+mrow("Longest triage",fmtDur(fm.triage))+mrow("Avg session",fmtDur(fm.avg));}
function tickOps(){if(VIEW!=="floor")return;var now=Math.floor(Date.now()/1000);[].forEach.call(document.querySelectorAll("#opslist .el"),function(e){e.textContent=fmtDur(now-(+e.dataset.s));});}
/* DEMO ticker: synthetic duty.log traffic so the floor reads as a live system
   when there is no collector. In LIVE mode liveTicker() replaces it with the
   real SESSION lines each poll brings back. */
function tickerEvent(){if(VIEW!=="floor"||LIVE)return;var alive=ROSTER.filter(function(u){return u.state!=="offline";});if(!alive.length)return;var u=alive[ri2(0,alive.length-1)],kind=kindOf(u.room),start=Math.random()<0.5,msg,cls="";
  if(start){var key=kind==="triage"?"board":REPONAMES[ri2(0,5)]+"#"+ri2(11,148);msg="SESSION START kind="+kind+" key="+key;}
  else{var rc=Math.random()<0.12?1:0,out=rc?"aborted (budget)":outcomeFor(kind);msg="SESSION END kind="+kind+" rc="+rc+" outcome="+out;cls=rc?"cr":"ok";}
  var s=document.getElementById("stream");if(!s)return;var el=document.createElement("div");el.className="l";var m=msg;if(cls==="ok")m=msg.replace(/(outcome=[^\s]+.*)$/,'<span class="ok">$1</span>');if(cls==="cr")m=msg.replace(/rc=1/,'<span class="cr">rc=1</span>');
  el.innerHTML='<span class="tt">'+clockStr()+'</span><span class="u" style="color:'+VENDORCOL(u.agent)+'">'+u.agent+'-'+u.room+'</span><span class="m">'+m+'</span>';
  s.appendChild(el);while(s.childNodes.length>30)s.removeChild(s.firstChild);s.scrollTop=s.scrollHeight;}

/* ===================== HERO ROBOT (heavy armored builder) ===================== */
function buildRobo(t,st){ return AGENT==="codex"?buildCodex(t,st):AGENT==="grok"?buildGrok(t,st):AGENT==="kimi"?buildKimi(t,st):buildClaude(t,st); }
function buildRim(){
  RR.globalCompositeOperation="source-over";RR.drawImage(robo,0,0);
  RR.globalCompositeOperation="destination-out";RR.drawImage(robo,-2.4,1.8);RR.drawImage(robo,-1.6,-2.6);
  RR.globalCompositeOperation="source-in";
  var rg=RR.createLinearGradient(70,0,450,0);rg.addColorStop(0,rgba(255,170,90,0.95));rg.addColorStop(0.5,rgba(150,175,205,0.4));rg.addColorStop(1,rgba(95,214,255,1));
  RR.fillStyle=rg;RR.fillRect(0,0,RW,RH);RR.globalCompositeOperation="source-over";
}
function buildClaude(t,st){
  var offl=st==="offline",work=st==="working";
  var ctxs=[RB,RE,RR];for(var i=0;i<3;i++){var c=ctxs[i];c.setTransform(1,0,0,1,0,0);c.clearRect(0,0,RW,RH);c.globalAlpha=1;c.globalCompositeOperation="source-over";c.filter="none";}
  var cx=260,gyf=560;
  var breath=(reduced||offl)?0:Math.sin(t*1.4)*2.0;
  var sT="#242e3d",sM="#131a25",sB="#080c13",ed="#2c3648",eH="#41506a",rc="#05080d";
  if(offl){sT="#181d25",sM="#0e131b",sB="#05080d",ed="#222932",eH="#2a323d";}
  var acc=offl?"#2b3038":"#ff9a3c", accH=offl?"#3a414c":"#ffca80", accL=offl?"#1c2129":"#a8500f";
  var corePulse=offl?0:(work?(0.58+0.2*Math.sin(t*7)):(0.32+0.15*Math.sin(t*2)));
  var g=RB;

  function em(c,fn){fn(c);} // draw emissive on given ctx
  function accGlow(c,x,y,w,h){ if(offl)return; var gg=c.createLinearGradient(0,y,0,y+h);gg.addColorStop(0,rgba(255,180,90,0.9));gg.addColorStop(1,rgba(200,90,20,0.9));c.fillStyle=gg;rr(c,x,y,w,h,1);c.fill(); }

  // ---------- BACKPACK heat-sink (behind, drawn first) ----------
  plate(g,[[cx-70,270+breath],[cx-40,250+breath],[cx+40,250+breath],[cx+70,270+breath],[cx+58,336+breath],[cx-58,336+breath]],sM,sB,ed);
  // exhaust stacks poking above shoulders
  [[-52,-1],[52,1]].forEach(function(k){var bx=cx+k[0];plate(g,[[bx-11,250+breath],[bx-9,196+breath],[bx+9,196+breath],[bx+11,250+breath]],sT,sB,ed);
    [RB,RE].forEach(function(c){accGlow(c,bx-5,200+breath,10,10);}); });

  // ---------- LEGS (mirror) ----------
  function leg(sgn){
    var lx=cx+sgn*30;
    // boot
    plate(g,[[lx-24,520+breath*0.2],[lx+20,520+breath*0.2],[lx+26,560],[lx-30,560]],sT,sB,ed);
    plate(g,[[lx-30,552],[lx+26,552],[lx+26,560],[lx-30,560]],"#0c1119","#03050a",null);
    // shin + hydraulic
    plate(g,[[lx-18,452+breath*0.4],[lx+18,452+breath*0.4],[lx+22,522],[lx-22,522]],sM,sB,ed);
    pl(g,lx+sgn*20,470,lx+sgn*20,516,"#0a0f18",5); pl(g,lx+sgn*20,470,lx+sgn*20,516,eH,1.4);
    // knee guard
    plate(g,[[lx-20,436+breath*0.5],[lx+20,436+breath*0.5],[lx+18,462],[lx-18,462]],sT,sM,ed);
    [RB,RE].forEach(function(c){if(!offl){c.fillStyle=rgba(255,150,70,0.8);c.fillRect(lx-4,446,8,3);}});
    // thigh
    plate(g,[[lx-22,360+breath*0.7],[lx+24,360+breath*0.7],[lx+20,440+breath*0.4],[lx-20,440+breath*0.4]],sM,sB,ed);
    pl(g,lx-10,372+breath*0.7,lx-8,432,rc,1);
  }
  leg(-1);leg(1);

  // ---------- PELVIS ----------
  plate(g,[[cx-34,342+breath],[cx+34,342+breath],[cx+30,378+breath*0.8],[cx-30,378+breath*0.8]],sT,sB,ed);
  // tassets
  plate(g,[[cx-40,344+breath],[cx-20,344+breath],[cx-24,382+breath*0.8],[cx-44,380+breath*0.8]],sM,sB,ed);
  plate(g,[[cx+20,344+breath],[cx+40,344+breath],[cx+44,380+breath*0.8],[cx+24,382+breath*0.8]],sM,sB,ed);
  // codpiece accent
  [RB,RE].forEach(function(c){accGlow(c,cx-3,352+breath,6,18);});

  // ---------- ABDOMEN (segmented) ----------
  for(var a=0;a<2;a++){var ay=305+a*20+breath;plate(g,[[cx-30,ay],[cx+30,ay],[cx+26,ay+18],[cx-26,ay+18]],sM,sB,ed);}

  // ---------- CHEST (broad, angled) ----------
  plate(g,[[cx-58,300+breath],[cx-66,236+breath],[cx-34,214+breath],[cx+34,214+breath],[cx+66,236+breath],[cx+58,300+breath]],sT,sM,ed);
  // upper chest bevel highlight
  plate(g,[[cx-60,240+breath],[cx-32,220+breath],[cx+32,220+breath],[cx+60,240+breath],[cx+54,250+breath],[cx-54,250+breath]],"#2c3849","#1a2331",null);
  // side intake vents (glow)
  [[-48,-1],[48,1]].forEach(function(k){var vx=cx+k[0]-(k[1]<0?10:0);
    RB.fillStyle=rc;rr(RB,vx,256+breath,10,30,2);RB.fill();
    [RB,RE].forEach(function(c){for(var s=0;s<4;s++){if(!offl){c.fillStyle=rgba(255,150,70,0.7);c.fillRect(vx+2,260+breath+s*7,6,3);}}});
  });
  // panel lines + rivets on chest
  pl(g,cx-40,262+breath,cx+40,262+breath,rc,1);
  rivet(g,cx-52,246+breath,eH);rivet(g,cx+52,246+breath,eH);rivet(g,cx-48,292+breath,eH);rivet(g,cx+48,292+breath,eH);
  // scratches (battle wear)
  if(!offl){g.strokeStyle="rgba(120,140,170,0.25)";g.lineWidth=1;g.beginPath();g.moveTo(cx+14,244+breath);g.lineTo(cx+30,258+breath);g.moveTo(cx-24,270+breath);g.lineTo(cx-12,282+breath);g.stroke();}
  // ---- REACTOR CORE (recessed, glowing) ----
  var coreY=262+breath;
  RB.fillStyle="#03060c";RB.beginPath();RB.arc(cx,coreY,22,0,7);RB.fill();
  RB.strokeStyle=ed;RB.lineWidth=2;RB.beginPath();RB.arc(cx,coreY,22,0,7);RB.stroke();
  // grille bars
  for(var b2=-2;b2<=2;b2++){RB.strokeStyle="#0a0f18";RB.lineWidth=2;RB.beginPath();RB.moveTo(cx-20,coreY+b2*7);RB.lineTo(cx+20,coreY+b2*7);RB.stroke();}
  [RB,RE].forEach(function(c){ if(offl){c.fillStyle="#161b22";c.beginPath();c.arc(cx,coreY,9,0,7);c.fill();return;}
    var cg=c.createRadialGradient(cx,coreY,1,cx,coreY,20);cg.addColorStop(0,rgba(255,225,160,corePulse));cg.addColorStop(0.4,rgba(255,150,60,0.7*corePulse));cg.addColorStop(1,"rgba(255,120,40,0)");c.fillStyle=cg;c.beginPath();c.arc(cx,coreY,20,0,7);c.fill();
    c.fillStyle=rgba(255,240,210,corePulse);c.beginPath();c.arc(cx,coreY,5,0,7);c.fill(); });

  // ---------- COLLAR / NECK ----------
  plate(g,[[cx-30,214+breath],[cx+30,214+breath],[cx+22,226+breath],[cx-22,226+breath]],sT,sM,ed);
  plate(g,[[cx-10,206+breath],[cx+10,206+breath],[cx+8,220+breath],[cx-8,220+breath]],sM,sB,null);

  // ---------- ARMS (mirror; right arm can raise when working) ----------
  var handR;
  function arm(sgn,mode){
    var shx=cx+sgn*62, shy=244+breath;
    // pauldron: 2 stacked angular plates (big, overhanging) -> intimidating shoulders
    plate(g,[[shx-sgn*4-28,shy-18],[shx-sgn*4+30,shy-22],[shx-sgn*4+34,shy+14],[shx-sgn*4-24,shy+18]],sT,sM,ed);
    plate(g,[[shx-sgn*2-26,shy+8],[shx-sgn*2+30,shy+6],[shx-sgn*2+26,shy+30],[shx-sgn*2-22,shy+30]],sM,sB,ed);
    // shoulder joint light
    [RB,RE].forEach(function(c){if(!offl){c.fillStyle=rgba(255,150,70,0.7);c.beginPath();c.arc(shx+sgn*2,shy+2,3,0,7);c.fill();}});
    if(mode==='reachdown'){ // reach forward + down (welding pose)
      var ex=shx+sgn*8, ey=shy+42;
      plate(g,[[shx-14,shy+22],[shx+18,shy+24],[ex+12,ey],[ex-12,ey]],sM,sB,ed);
      var fx=ex - sgn*22, fy=ey+34;
      plate(g,[[ex-12,ey-2],[ex+12,ey],[fx+12,fy-4],[fx-8,fy-8]],sT,sM,ed);
      plate(g,[[fx-9,fy-8],[fx+13,fy-6],[fx+11,fy+12],[fx-11,fy+10]],sM,sB,ed); // gauntlet
      plate(g,[[fx-2,fy+2],[fx+10,fy-3],[fx+14,fy+2],[fx+2,fy+9]],"#2a3444","#12181f","#3d4c63"); // torch
      handR={x:fx+13,y:fy+2};
    } else if(mode==='raiseup'){ // forearm raised, device held up in front of chest (inspect/dispatch)
      var ex3=shx+sgn*6, ey3=shy+40;
      plate(g,[[shx-15,shy+22],[shx+17,shy+24],[ex3+12,ey3],[ex3-12,ey3]],sM,sB,ed); // upper arm
      var fx3=ex3 - sgn*26, fy3=ey3-32;   // forearm up + inward
      plate(g,[[ex3-12,ey3],[ex3+12,ey3-2],[fx3+12,fy3+6],[fx3-8,fy3-2]],sT,sM,ed);
      plate(g,[[fx3-9,fy3-6],[fx3+13,fy3-4],[fx3+11,fy3+14],[fx3-11,fy3+12]],sM,sB,ed); // gauntlet
      if(sgn>0)handR={x:fx3+2,y:fy3+4};
    } else {
      var ex2=shx+sgn*4, ey2=shy+56;
      plate(g,[[shx-16,shy+22],[shx+16,shy+24],[ex2+14,ey2],[ex2-14,ey2]],sM,sB,ed);
      [RB,RE].forEach(function(c){if(!offl){c.fillStyle=rgba(255,150,70,0.6);c.fillRect(ex2-3,ey2-4,6,3);}});
      plate(g,[[ex2-15,ey2-2],[ex2+15,ey2-2],[ex2+13,ey2+58],[ex2-13,ey2+58]],sT,sM,ed);
      pl(g,ex2-6,ey2+8,ex2-6,ey2+50,rc,1);
      plate(g,[[ex2-13,ey2+56],[ex2+13,ey2+56],[ex2+11,ey2+74],[ex2-11,ey2+74]],sM,sB,ed);
      if(sgn>0)handR={x:ex2,y:ey2+64};
    }
  }
  arm(-1,'down');
  arm(1, work ? (ROOM==="builder"?'reachdown':'raiseup') : 'down');
  // room-specific handheld device for the raised-arm roles
  if(work&&ROOM!=="builder"&&handR){var h=handR;
    if(ROOM==="reviewer"){ plate(g,[[h.x-3,h.y-9],[h.x+17,h.y-11],[h.x+17,h.y+2],[h.x-3,h.y+4]],"#1a2836","#0c1620","#3a5570");
      [RB,RE].forEach(function(c){if(!offl){c.fillStyle=rgba(130,205,255,0.75);c.fillRect(h.x+1,h.y-7,11,7);}}); }
    else { plate(g,[[h.x-2,h.y-11],[h.x+9,h.y-13],[h.x+12,h.y+4],[h.x+1,h.y+6]],"#241a30","#140e1c","#4a3a5e");
      [RB,RE].forEach(function(c){if(!offl){c.fillStyle=rgba(201,139,255,0.75);c.fillRect(h.x+2,h.y-9,4,5);}}); }
  }

  // ---------- HEAD (small, menacing helmet) ----------
  var hy=150+breath, hcx=cx;
  // neck
  plate(g,[[hcx-9,206+breath],[hcx+9,206+breath],[hcx+7,196+breath],[hcx-7,196+breath]],sM,sB,null);
  // helmet dome + jaw (angular)
  plate(g,[[hcx-24,hy+34],[hcx-26,hy+10],[hcx-14,hy-6],[hcx+14,hy-6],[hcx+26,hy+10],[hcx+24,hy+34],[hcx+12,hy+48],[hcx-12,hy+48]],sT,sM,ed);
  // brow crest
  plate(g,[[hcx-16,hy+2],[hcx+16,hy+2],[hcx+12,hy-10],[hcx-12,hy-10]],"#2e3a4c","#1a2331",ed);
  pl(g,hcx,hy-10,hcx,hy+2,rc,1);
  // side vents / breather
  [[-1],[1]].forEach(function(k){var s=k[0];RB.fillStyle=rc;for(var v=0;v<3;v++)RB.fillRect(hcx+s*16-(s<0?4:0),hy+16+v*6,4,3);});
  // visor slit (glow, horizontal, angled down = menacing)
  RB.fillStyle="#03060d";poly(RB,[[hcx-20,hy+14],[hcx+20,hy+14],[hcx+18,hy+26],[hcx-18,hy+26]]);RB.fill();
  [RB,RE].forEach(function(c){ if(offl){c.fillStyle="#20262e";c.fillRect(hcx-16,hy+18,32,3);return;}
    var vg=c.createLinearGradient(hcx-18,0,hcx+18,0);vg.addColorStop(0,rgba(255,170,80,corePulse));vg.addColorStop(1,rgba(255,120,50,corePulse));c.fillStyle=vg;poly(c,[[hcx-17,hy+16],[hcx+17,hy+16],[hcx+15,hy+24],[hcx-15,hy+24]]);c.fill();
    c.fillStyle=rgba(255,240,210,corePulse);c.fillRect(hcx-14,hy+18,7,2); });
  // antenna
  pl(g,hcx+18,hy-4,hcx+24,hy-18,eH,1.6);
  [RB,RE].forEach(function(c){if(!offl){c.fillStyle="rgba(255,80,70,0.9)";c.beginPath();c.arc(hcx+24,hy-18,2,0,7);c.fill();}});

  buildRim();
  return {hand:handR||{x:cx,y:400},coreY:262+breath,hy:hy,offl:offl,work:work};
}

/* ===================== CODEX — heavy armored 8-legged spider (teal) ===================== */
function buildCodex(t,st){
  var offl=st==="offline", work=st==="working";
  var CX=[RB,RE,RR];for(var q=0;q<3;q++){var c0=CX[q];c0.setTransform(1,0,0,1,0,0);c0.clearRect(0,0,RW,RH);c0.globalAlpha=1;c0.globalCompositeOperation="source-over";c0.filter="none";}
  var cx=260, g=RB;
  var sT="#242e3d",sM="#131a25",sB="#080c13",ed="#2c3648",eH="#41506a",rc="#05080d";
  if(offl){sT="#181d25";sM="#0e131b";sB="#05080d";ed="#222932";eH="#2a323d";}
  var TEAL=offl?[70,80,92]:[55,212,166], TEALH=offl?[110,120,132]:[150,240,214];
  function te(a){return "rgba("+TEAL[0]+","+TEAL[1]+","+TEAL[2]+","+a+")";}
  function teh(a){return "rgba("+TEALH[0]+","+TEALH[1]+","+TEALH[2]+","+a+")";}
  var pulse=offl?0:(work?(0.6+0.28*Math.sin(t*6)):(0.34+0.16*Math.sin(t*2)));
  var bob=(offl||reduced)?0:Math.round(Math.sin(t*1.5)*1.4);
  var slump=offl?18:0, BY=356+bob+slump;
  function limbSeg(c,x0,y0,x1,y1,w0,w1,top,bot){var dx=x1-x0,dy=y1-y0,ln=Math.hypot(dx,dy)||1,nx=-dy/ln,ny=dx/ln;plate(c,[[x0+nx*w0,y0+ny*w0],[x1+nx*w1,y1+ny*w1],[x1-nx*w1,y1-ny*w1],[x0-nx*w0,y0-ny*w0]],top,bot,ed);}
  function joint(c,x,y,r){c.fillStyle=sT;c.beginPath();c.arc(x,y,r,0,7);c.fill();c.fillStyle=eH;c.beginPath();c.arc(x-1,y-1,1.2,0,7);c.fill();}

  // ---- 8 legs (behind body) ----
  var rootY=[-4,6,16], footX=[150,106,60], footY=[550,558,552], kneeH=[74,92,78]; // 6 legs, wider stance
  function drawLeg(sgn,i){
    var rx=cx+sgn*24, ry=BY+rootY[i], fx=cx+sgn*footX[i], fy=footY[i];
    var k1h=Math.max(12,kneeH[i]-slump*1.3);
    var k1x=cx+sgn*(footX[i]*0.64+16), k1y=BY-k1h;                    // knee: high → steep femur
    var k2x=cx+sgn*(footX[i]+30), k2y=BY+(fy-BY)*(0.56+(offl?0.16:0)); // ankle: low + well beyond foot → sharp flex
    g.fillStyle=sM;g.beginPath();g.arc(rx,ry,5.5,0,7);g.fill();  // coxa stub
    limbSeg(g,rx,ry,k1x,k1y,7.5,5.5,sM,sB);   // femur: up + out
    limbSeg(g,k1x,k1y,k2x,k2y,5.5,4,sT,sB);   // tibia: down + out past the foot
    limbSeg(g,k2x,k2y,fx,fy,4.5,2.6,sM,sB);   // tarsus: down + in to the foot (the flex)
    joint(g,k1x,k1y,5.5); joint(g,k2x,k2y,4.5);
    g.fillStyle=sB;g.beginPath();g.moveTo(fx-3,fy-3);g.lineTo(fx+3,fy-3);g.lineTo(fx+sgn*2,fy+5);g.closePath();g.fill();
    if(!offl){RB.fillStyle=te(0.85);RB.fillRect(fx-1,fy-4,2,2);RE.fillStyle=te(0.9);RE.fillRect(fx-1,fy-4,2,2);}
  }
  for(var i=0;i<3;i++){drawLeg(-1,i);drawLeg(1,i);}

  // ---- abdomen (rear/upper rounded hull) ----
  var ax=cx, ay=BY-44, aw=78, ah=56;
  var abg=g.createLinearGradient(0,ay-ah,0,ay+ah);abg.addColorStop(0,sT);abg.addColorStop(1,sB);
  g.fillStyle=abg;g.beginPath();g.ellipse(ax,ay,aw,ah,0,0,7);g.fill();
  g.strokeStyle=ed;g.lineWidth=1.4;g.beginPath();g.ellipse(ax,ay,aw,ah,0,0,7);g.stroke();
  // carapace chevrons (nested), a top-left sheen, and rivets
  g.strokeStyle="#2c3849";g.lineWidth=1.4;for(var cvr=0;cvr<3;cvr++){var rr2=0.5+cvr*0.17;g.beginPath();g.moveTo(ax-aw*rr2,ay-ah*0.12);g.quadraticCurveTo(ax,ay-ah*(0.66+cvr*0.09),ax+aw*rr2,ay-ah*0.12);g.stroke();}
  g.strokeStyle=eH;g.lineWidth=1;g.beginPath();g.ellipse(ax-6,ay-8,aw-16,ah-16,0,Math.PI*1.02,Math.PI*1.62);g.stroke();
  g.strokeStyle=rc;g.lineWidth=1;g.beginPath();g.moveTo(ax-aw+10,ay+2);g.lineTo(ax+aw-10,ay+2);g.stroke();
  rivet(g,ax-aw+16,ay+6,eH);rivet(g,ax+aw-16,ay+6,eH);rivet(g,ax,ay+ah-9,eH);
  // spinneret nozzles (rear-top)
  for(var n=-1;n<=1;n++){var nx2=ax+n*12;plate(g,[[nx2-4,ay-ah+2],[nx2+4,ay-ah+2],[nx2+3,ay-ah-12],[nx2-3,ay-ah-12]],sM,sB,ed);if(!offl){RB.fillStyle=te(0.55);RB.fillRect(nx2-2,ay-ah-12,4,3);RE.fillStyle=te(0.6);RE.fillRect(nx2-2,ay-ah-12,4,3);}}

  // ---- reactor core (abdomen front) ----
  var coreY=ay+10;
  RB.fillStyle="#03060c";RB.beginPath();RB.arc(cx,coreY,19,0,7);RB.fill();
  RB.strokeStyle=ed;RB.lineWidth=2;RB.beginPath();RB.arc(cx,coreY,19,0,7);RB.stroke();
  for(var b2=-1;b2<=1;b2++){RB.strokeStyle="#0a0f18";RB.lineWidth=2;RB.beginPath();RB.moveTo(cx-17,coreY+b2*7);RB.lineTo(cx+17,coreY+b2*7);RB.stroke();}
  [RB,RE].forEach(function(c){if(offl){c.fillStyle="#161b22";c.beginPath();c.arc(cx,coreY,8,0,7);c.fill();return;}var cg=c.createRadialGradient(cx,coreY,1,cx,coreY,19);cg.addColorStop(0,teh(pulse));cg.addColorStop(0.4,te(0.75*pulse));cg.addColorStop(1,te(0));c.fillStyle=cg;c.beginPath();c.arc(cx,coreY,19,0,7);c.fill();c.fillStyle=teh(pulse);c.beginPath();c.arc(cx,coreY,4.5,0,7);c.fill();});

  // ---- cephalothorax (front hull) + eye cluster ----
  var hxx=cx, hy2=BY+22;
  plate(g,[[hxx-42,hy2-24],[hxx+42,hy2-24],[hxx+34,hy2+26],[hxx-34,hy2+26]],sT,sM,ed);
  plate(g,[[hxx-40,hy2-24],[hxx+40,hy2-24],[hxx+36,hy2-14],[hxx-36,hy2-14]],"#2c3849","#1a2331",null);
  plate(g,[[hxx-14,hy2+22],[hxx-4,hy2+22],[hxx-6,hy2+34],[hxx-16,hy2+32]],sM,sB,ed);
  plate(g,[[hxx+4,hy2+22],[hxx+14,hy2+22],[hxx+16,hy2+32],[hxx+6,hy2+34]],sM,sB,ed);
  RB.fillStyle="#04070d";RB.fillRect(hxx-26,hy2-10,52,22);
  var eyes=[[hxx-12,hy2+2,3.2],[hxx+12,hy2+2,3.2],[hxx-20,hy2-6,1.8],[hxx+20,hy2-6,1.8],[hxx-7,hy2+12,1.6],[hxx+7,hy2+12,1.6]];
  eyes.forEach(function(e){[RB,RE].forEach(function(c){if(offl){c.fillStyle="#20262e";c.beginPath();c.arc(e[0],e[1],e[2]*0.7,0,7);c.fill();return;}var eg=c.createRadialGradient(e[0],e[1],0.4,e[0],e[1],e[2]*2.4);eg.addColorStop(0,te(0.55*pulse));eg.addColorStop(1,te(0));c.fillStyle=eg;c.beginPath();c.arc(e[0],e[1],e[2]*2.4,0,7);c.fill();c.fillStyle=teh(0.75+0.25*pulse);c.beginPath();c.arc(e[0],e[1],e[2],0,7);c.fill();});});

  // ---- front manipulators ----
  var handR;
  (function(){var rx=hxx-20,ry=hy2+14,ex=hxx-30,ey=hy2+30,tx2=hxx-18,ty=hy2+42;limbSeg(g,rx,ry,ex,ey,4,3,sM,sB);limbSeg(g,ex,ey,tx2,ty,3,2,sT,sB);joint(g,ex,ey,3);})();
  (function(){var rx=hxx+20,ry=hy2+14;
    if(work){var ex=hxx+30,ey=hy2-4,tx2=hxx+22,ty=hy2-30;limbSeg(g,rx,ry,ex,ey,4,3,sM,sB);limbSeg(g,ex,ey,tx2,ty,3,2.2,sT,sB);joint(g,ex,ey,3);plate(g,[[tx2-5,ty-5],[tx2+6,ty-6],[tx2+5,ty+5],[tx2-6,ty+4]],sM,sB,ed);handR={x:tx2+2,y:ty};}
    else{var ex=hxx+30,ey=hy2+30,tx2=hxx+18,ty=hy2+42;limbSeg(g,rx,ry,ex,ey,4,3,sM,sB);limbSeg(g,ex,ey,tx2,ty,3,2,sT,sB);joint(g,ex,ey,3);handR={x:tx2,y:ty};}
  })();
  if(work&&handR){var h=handR;
    if(ROOM==="builder"){plate(g,[[h.x-2,h.y+2],[h.x+10,h.y-3],[h.x+14,h.y+2],[h.x+2,h.y+9]],"#2a3444","#12181f","#3d4c63");}
    else if(ROOM==="reviewer"){plate(g,[[h.x-3,h.y-9],[h.x+15,h.y-11],[h.x+15,h.y+2],[h.x-3,h.y+4]],"#1a2836","#0c1620","#3a5570");if(!offl){RB.fillStyle="rgba(130,205,255,0.75)";RB.fillRect(h.x+1,h.y-7,10,7);RE.fillStyle="rgba(130,205,255,0.7)";RE.fillRect(h.x+1,h.y-7,10,7);}}
    else{plate(g,[[h.x-2,h.y-11],[h.x+9,h.y-13],[h.x+12,h.y+4],[h.x+1,h.y+6]],"#241a30","#140e1c","#4a3a5e");if(!offl){RB.fillStyle="rgba(201,139,255,0.75)";RB.fillRect(h.x+2,h.y-9,4,5);RE.fillStyle="rgba(201,139,255,0.7)";RE.fillRect(h.x+2,h.y-9,4,5);}}
  }

  buildRim();
  return {hand:handR||{x:cx+18,y:BY+42},coreY:coreY,hy:hy2-10,offl:offl,work:work};
}

/* ===================== GROK — floating astronaut w/ jetpack (purple) ===================== */
function buildGrok(t,st){
  var offl=st==="offline", work=st==="working";
  var GX=[RB,RE,RR];for(var q=0;q<3;q++){var c0=GX[q];c0.setTransform(1,0,0,1,0,0);c0.clearRect(0,0,RW,RH);c0.globalAlpha=1;c0.globalCompositeOperation="source-over";c0.filter="none";}
  var cx=260, g=RB;
  var F=1.8, OY=-368, TA=260-260*F;                        // ~1.27x larger + floats a touch higher
  RB.setTransform(F,0,0,F,TA,OY);RE.setTransform(F,0,0,F,TA,OY);
  function TX(x){return F*x+TA;} function TY(y){return F*y+OY;}
  var sT="#2a3040",sM="#171c27",sB="#0a0d15",ed="#323a4c",eH="#48566e",rc="#06090f";
  if(offl){sT="#1b1f27";sM="#0f131a";sB="#070a0f";ed="#242a33";eH="#2e3540";}
  var PUR=offl?[74,80,92]:[176,124,255], PURH=offl?[120,126,138]:[220,198,255];
  function pu(a){return "rgba("+PUR[0]+","+PUR[1]+","+PUR[2]+","+a+")";}
  function puh(a){return "rgba("+PURH[0]+","+PURH[1]+","+PURH[2]+","+a+")";}
  var pulse=offl?0:(work?(0.6+0.28*Math.sin(t*6)):(0.34+0.16*Math.sin(t*2)));
  var thr=offl?0:(work?1:0.7)*(0.82+0.18*Math.sin(t*22));
  var bob=(offl||reduced)?0:Math.round(Math.sin(t*1.8)*3);
  var BY=offl?392:364+bob;
  function limbSeg(c,x0,y0,x1,y1,w0,w1,top,bot){var dx=x1-x0,dy=y1-y0,ln=Math.hypot(dx,dy)||1,nx=-dy/ln,ny=dx/ln;plate(c,[[x0+nx*w0,y0+ny*w0],[x1+nx*w1,y1+ny*w1],[x1-nx*w1,y1-ny*w1],[x0-nx*w0,y0-ny*w0]],top,bot,ed);}

  // ---- thruster exhaust plumes (behind, downward) ----
  if(!offl){[-1,1].forEach(function(sg){var nx2=cx+sg*24, ny=BY+32;
    [RB,RE].forEach(function(c){c.save();c.globalCompositeOperation="lighter";var bx=nx2+sg*8,by2=ny+92;var pl2=c.createLinearGradient(nx2,ny,bx,by2);pl2.addColorStop(0,puh(0.72*thr));pl2.addColorStop(0.3,pu(0.42*thr));pl2.addColorStop(1,pu(0));c.fillStyle=pl2;c.beginPath();c.moveTo(nx2-5,ny);c.lineTo(nx2+5,ny);c.lineTo(bx+9,by2);c.lineTo(bx-9,by2);c.closePath();c.fill();c.fillStyle="rgba(255,255,255,"+(0.6*thr)+")";c.fillRect(nx2-2,ny-2,4,12);c.restore();});});}

  // ---- backpack + side thruster pods + nozzles ----
  plate(g,[[cx-20,BY-30],[cx+20,BY-30],[cx+18,BY+26],[cx-18,BY+26]],sM,sB,ed);
  [-1,1].forEach(function(sg){
    plate(g,[[cx+sg*18,BY-10],[cx+sg*30,BY-8],[cx+sg*30,BY+20],[cx+sg*18,BY+18]],sM,sB,ed);           // pod
    plate(g,[[cx+sg*24-5,BY+18],[cx+sg*24+5,BY+18],[cx+sg*24+4,BY+32],[cx+sg*24-4,BY+32]],sT,sB,ed);   // nozzle
    if(!offl){RB.fillStyle=pu(0.6*thr);RB.fillRect(cx+sg*24-3,BY+29,6,3);RE.fillStyle=pu(0.6*thr);RE.fillRect(cx+sg*24-3,BY+29,6,3);}
  });

  // ---- legs (dangling; droop more when offline) ----
  function leg(sgn){var hxp=cx+sgn*12,hy0=BY+26,kx=hxp+sgn*(offl?4:10),ky=hy0+(offl?50:40),fx=hxp+sgn*2,fy=ky+(offl?40:38);
    limbSeg(g,hxp,hy0,kx,ky,7,6,sM,sB);limbSeg(g,kx,ky,fx,fy,6,5,sT,sB);
    plate(g,[[fx-6,fy-2],[fx+6,fy-2],[fx+9,fy+8],[fx-7,fy+8]],sM,sB,ed);}
  leg(-1);leg(1);

  // ---- torso (spacesuit) ----
  plate(g,[[cx-24,BY-30],[cx+24,BY-30],[cx+27,BY+26],[cx-27,BY+26]],sT,sM,ed);
  plate(g,[[cx-24,BY-30],[cx+24,BY-30],[cx+22,BY-20],[cx-22,BY-20]],"#333b4d","#202735",null);
  pl(g,cx,BY-18,cx,BY+22,rc,1);
  RB.fillStyle="#05080e";RB.fillRect(cx-10,BY-6,20,16);
  [RB,RE].forEach(function(c){if(!offl){c.fillStyle=pu(0.55+0.3*pulse);c.fillRect(cx-8,BY-4,16,12);c.fillStyle=puh(pulse);c.fillRect(cx-6,BY-2,5,3);c.fillStyle=puh(0.7*pulse);c.fillRect(cx+1,BY+3,4,2);}else{c.fillStyle="#1a2028";c.fillRect(cx-8,BY-4,16,12);}});
  plate(g,[[cx-34,BY-28],[cx-18,BY-30],[cx-16,BY-14],[cx-32,BY-12]],sT,sB,ed);
  plate(g,[[cx+18,BY-30],[cx+34,BY-28],[cx+32,BY-12],[cx+16,BY-14]],sT,sB,ed);
  // life-support hose (pod → chest) + a couple of suit ribs
  g.strokeStyle="#0d1219";g.lineWidth=4;g.beginPath();g.moveTo(cx-24,BY+12);g.quadraticCurveTo(cx-27,BY-4,cx-11,BY-3);g.stroke();
  g.strokeStyle="rgba(84,96,116,0.5)";g.lineWidth=1;g.beginPath();g.moveTo(cx-24,BY+12);g.quadraticCurveTo(cx-27,BY-4,cx-11,BY-3);g.stroke();
  g.strokeStyle=rc;g.lineWidth=1;g.beginPath();g.moveTo(cx-22,BY+2);g.lineTo(cx+22,BY+2);g.moveTo(cx-20,BY+14);g.lineTo(cx+20,BY+14);g.stroke();

  // ---- arms ----
  var handR;
  (function(){var sx=cx-30,sy=BY-16,ex=cx-34,ey=BY+6,gx2=cx-30,gy=BY+26;limbSeg(g,sx,sy,ex,ey,6,5,sM,sB);limbSeg(g,ex,ey,gx2,gy,5,4,sT,sB);g.fillStyle="#cfd6e2";g.beginPath();g.arc(gx2,gy+2,4,0,7);g.fill();})();
  (function(){var sx=cx+30,sy=BY-16;
    if(work){var ex=cx+38,ey=BY-14,gx2=cx+30,gy=BY-40;limbSeg(g,sx,sy,ex,ey,6,5,sM,sB);limbSeg(g,ex,ey,gx2,gy,5,4,sT,sB);g.fillStyle="#cfd6e2";g.beginPath();g.arc(gx2,gy,4,0,7);g.fill();handR={x:gx2+2,y:gy};}
    else{var ex=cx+34,ey=BY+6,gx2=cx+30,gy=BY+26;limbSeg(g,sx,sy,ex,ey,6,5,sM,sB);limbSeg(g,ex,ey,gx2,gy,5,4,sT,sB);g.fillStyle="#cfd6e2";g.beginPath();g.arc(gx2,gy+2,4,0,7);g.fill();handR={x:gx2,y:gy};}
  })();
  if(work&&handR){var h=handR;
    if(ROOM==="builder"){plate(g,[[h.x-2,h.y+2],[h.x+10,h.y-3],[h.x+14,h.y+2],[h.x+2,h.y+9]],"#2a3444","#12181f","#3d4c63");}
    else if(ROOM==="reviewer"){plate(g,[[h.x-3,h.y-9],[h.x+15,h.y-11],[h.x+15,h.y+2],[h.x-3,h.y+4]],"#1a2836","#0c1620","#3a5570");if(!offl){RB.fillStyle="rgba(130,205,255,0.75)";RB.fillRect(h.x+1,h.y-7,10,7);RE.fillStyle="rgba(130,205,255,0.7)";RE.fillRect(h.x+1,h.y-7,10,7);}}
    else{plate(g,[[h.x-2,h.y-11],[h.x+9,h.y-13],[h.x+12,h.y+4],[h.x+1,h.y+6]],"#241a30","#140e1c","#4a3a5e");if(!offl){RB.fillStyle="rgba(201,139,255,0.75)";RB.fillRect(h.x+2,h.y-9,4,5);RE.fillStyle="rgba(201,139,255,0.7)";RE.fillRect(h.x+2,h.y-9,4,5);}}
  }

  // ---- neck ring + helmet ----
  plate(g,[[cx-10,BY-34],[cx+10,BY-34],[cx+8,BY-28],[cx-8,BY-28]],sT,sB,ed);
  var HY=BY-52, hr=20;
  g.fillStyle=sM;g.beginPath();g.arc(cx,HY,hr+2,0,7);g.fill();g.strokeStyle=ed;g.lineWidth=1.4;g.beginPath();g.arc(cx,HY,hr+2,0,7);g.stroke();
  g.fillStyle="#070a14";g.beginPath();g.arc(cx,HY,hr,0,7);g.fill();
  if(!offl){var stars=[[-8,-6],[4,-9],[10,-2],[-4,4],[7,6],[-10,2],[1,-3]];stars.forEach(function(sp,si){RB.fillStyle="rgba(220,210,255,"+(0.35+0.4*Math.sin(t*2+si*1.3))+")";RB.fillRect(cx+sp[0],HY+sp[1],1,1);});}
  [RB,RE].forEach(function(c){if(offl){c.fillStyle="#20262e";c.fillRect(cx-3,HY-1,6,3);return;}var eg=c.createRadialGradient(cx,HY,1,cx,HY,11);eg.addColorStop(0,puh(0.8+0.2*pulse));eg.addColorStop(0.5,pu(0.5*pulse));eg.addColorStop(1,pu(0));c.fillStyle=eg;c.beginPath();c.arc(cx,HY,11,0,7);c.fill();c.fillStyle=puh(0.9);c.beginPath();c.arc(cx,HY,2.4,0,7);c.fill();});
  g.strokeStyle="rgba(180,200,240,0.4)";g.lineWidth=2;g.beginPath();g.arc(cx-3,HY-3,hr-5,Math.PI*1.05,Math.PI*1.55);g.stroke();
  pl(g,cx+hr-4,HY-hr+6,cx+hr+4,HY-hr-6,eH,1.6);
  if(!offl){RB.fillStyle="rgba(255,80,70,0.9)";RB.beginPath();RB.arc(cx+hr+4,HY-hr-6,2,0,7);RB.fill();RE.fillStyle="rgba(255,80,70,0.8)";RE.beginPath();RE.arc(cx+hr+4,HY-hr-6,2,0,7);RE.fill();}

  RB.setTransform(1,0,0,1,0,0);RE.setTransform(1,0,0,1,0,0);RR.setTransform(1,0,0,1,0,0);
  buildRim();
  var hh=handR||{x:cx+30,y:BY+26};
  return {hand:{x:TX(hh.x),y:TY(hh.y)},coreY:TY(BY),hy:TY(HY-20),offl:offl,work:work};
}

/* ===================== KIMI — hovering companion drone, screen-face (pink) ===================== */
function buildKimi(t,st){
  var offl=st==="offline", work=st==="working";
  var GX=[RB,RE,RR];for(var q=0;q<3;q++){var c0=GX[q];c0.setTransform(1,0,0,1,0,0);c0.clearRect(0,0,RW,RH);c0.globalAlpha=1;c0.globalCompositeOperation="source-over";c0.filter="none";}
  var cx=260, g=RB;
  var F=2.25, OY=-440, TA=260-260*F;                        // floats higher
  RB.setTransform(F,0,0,F,TA,OY);RE.setTransform(F,0,0,F,TA,OY);
  function TX(x){return F*x+TA;} function TY(y){return F*y+OY;}
  var sT="#2a3140",sM="#171d28",sB="#0a0e16",ed="#333b4d",eH="#4a5872",rc="#06090f";
  if(offl){sT="#1b1f27";sM="#0f131a";sB="#070a0f";ed="#242a33";eH="#2e3540";}
  var PK=offl?[74,80,92]:[255,114,182], PKH=offl?[120,126,138]:[255,182,214];
  function pk(a){return "rgba("+PK[0]+","+PK[1]+","+PK[2]+","+a+")";}
  function pkh(a){return "rgba("+PKH[0]+","+PKH[1]+","+PKH[2]+","+a+")";}
  function limbSeg(c,x0,y0,x1,y1,w0,w1,top,bot){var dx=x1-x0,dy=y1-y0,ln=Math.hypot(dx,dy)||1,nx=-dy/ln,ny=dx/ln;plate(c,[[x0+nx*w0,y0+ny*w0],[x1+nx*w1,y1+ny*w1],[x1-nx*w1,y1-ny*w1],[x0-nx*w0,y0-ny*w0]],top,bot,ed);}
  var pulse=offl?0:(work?(0.6+0.28*Math.sin(t*6)):(0.36+0.16*Math.sin(t*2)));
  var hov=offl?0:(0.8+0.2*Math.sin(t*10));
  var bob=(offl||reduced)?0:Math.round(Math.sin(t*1.7)*3);
  var BY=offl?404:360+bob;
  var blink=(!offl&&!reduced&&Math.sin(t*0.7)>0.986)?1:0;

  // ---- hover skirt glow + downward wash ----
  if(!offl){var sky=BY+30;[RB,RE].forEach(function(c){c.save();c.globalCompositeOperation="lighter";
    var rg2=c.createRadialGradient(cx,sky,2,cx,sky,46);rg2.addColorStop(0,pkh(0.42*hov));rg2.addColorStop(0.5,pk(0.22*hov));rg2.addColorStop(1,pk(0));c.fillStyle=rg2;c.beginPath();c.ellipse(cx,sky,46,12,0,0,7);c.fill();
    var dw=c.createLinearGradient(0,sky,0,sky+54);dw.addColorStop(0,pk(0.2*hov));dw.addColorStop(1,pk(0));c.fillStyle=dw;c.beginPath();c.moveTo(cx-30,sky);c.lineTo(cx+30,sky);c.lineTo(cx+42,sky+54);c.lineTo(cx-42,sky+54);c.closePath();c.fill();c.restore();});}

  // ---- ear antennae (behind body) ----
  [-1,1].forEach(function(sg){var ex=cx+sg*22, ey=BY-30;pl(g,ex,ey,ex+sg*10,ey-26,eH,3);g.fillStyle=sM;g.beginPath();g.arc(ex+sg*10,ey-26,5,0,7);g.fill();
    if(!offl){RB.fillStyle=pkh(0.7+0.3*pulse);RB.beginPath();RB.arc(ex+sg*10,ey-26,2.5,0,7);RB.fill();RE.fillStyle=pk(0.8);RE.beginPath();RE.arc(ex+sg*10,ey-26,2.5,0,7);RE.fill();}});

  // ---- side thruster pods ----
  [-1,1].forEach(function(sg){plate(g,[[cx+sg*34,BY-8],[cx+sg*46,BY-4],[cx+sg*46,BY+14],[cx+sg*34,BY+12]],sM,sB,ed);if(!offl){RB.fillStyle=pk(0.6*hov);RB.fillRect(cx+sg*40,BY+9,5,3);RE.fillStyle=pk(0.6*hov);RE.fillRect(cx+sg*40,BY+9,5,3);}});

  // ---- hover skirt casing ----
  plate(g,[[cx-34,BY+20],[cx+34,BY+20],[cx+28,BY+34],[cx-28,BY+34]],sM,sB,ed);
  if(!offl){RB.fillStyle=pk(0.5*hov);RB.fillRect(cx-26,BY+31,52,2);RE.fillStyle=pk(0.5*hov);RE.fillRect(cx-26,BY+31,52,2);}

  // ---- body (rounded screen-face casing) ----
  var bx=cx-38,by0=BY-34,bw=76,bh=58,br=15;
  var bgr=g.createLinearGradient(0,by0,0,by0+bh);bgr.addColorStop(0,sT);bgr.addColorStop(1,sB);
  rr(g,bx,by0,bw,bh,br);g.fillStyle=bgr;g.fill();g.strokeStyle=ed;g.lineWidth=1.4;g.stroke();
  g.strokeStyle=eH;g.lineWidth=1;g.beginPath();g.moveTo(bx+8,by0+3);g.lineTo(bx+bw-8,by0+3);g.stroke();
  // screen
  var sx=bx+8,sy=by0+8,sw=bw-16,sh=bh-16;rr(g,sx,sy,sw,sh,9);g.fillStyle="#05080e";g.fill();g.strokeStyle=rc;g.lineWidth=1;g.stroke();
  if(!offl){RB.fillStyle=pk(0.05);for(var sl=sy+3;sl<sy+sh;sl+=3)RB.fillRect(sx+2,sl,sw-4,1);}
  // glossy glass highlight (top-left)
  g.save();rr(g,sx,sy,sw,sh,9);g.clip();g.fillStyle="rgba(184,206,246,0.07)";g.beginPath();g.moveTo(sx,sy);g.lineTo(sx+sw*0.55,sy);g.lineTo(sx,sy+sh*0.62);g.closePath();g.fill();g.restore();

  // ---- face (per state) ----
  var e1=cx-13,e2=cx+13,ey2=by0+bh*0.44;
  if(offl){RB.fillStyle="#20262e";RB.fillRect(e1-4,ey2,8,2);RB.fillRect(e2-4,ey2,8,2);}
  else{
    [e1,e2].forEach(function(exx){[RB,RE].forEach(function(c){var eg=c.createRadialGradient(exx,ey2,0.5,exx,ey2,10);eg.addColorStop(0,pkh(0.8+0.2*pulse));eg.addColorStop(0.5,pk(0.5*pulse));eg.addColorStop(1,pk(0));c.fillStyle=eg;c.beginPath();c.arc(exx,ey2,10,0,7);c.fill();});});
    var eh=blink?1:(work?4:7), ew=6;
    [e1,e2].forEach(function(exx){[RB,RE].forEach(function(c){c.fillStyle=pkh(0.92);rr(c,exx-ew/2,ey2-eh/2,ew,eh,2);c.fill();});RB.fillStyle="rgba(255,255,255,0.85)";RB.fillRect(exx-1,ey2-eh/2+1,2,2);});
    RB.strokeStyle=pk(0.6);RB.lineWidth=1.4;RB.beginPath();
    if(work){RB.moveTo(cx-5,by0+bh*0.72);RB.lineTo(cx+5,by0+bh*0.72);}
    else{RB.arc(cx,by0+bh*0.64,5,0.12*Math.PI,0.88*Math.PI);}
    RB.stroke();
  }

  // ---- manipulator arm (deploys when working) ----
  var handR;
  (function(){var rx=cx+28,ry=BY+14;
    if(work){var ex=cx+42,ey=BY-10,gx2=cx+44,gy=BY-36;limbSeg(g,rx,ry,ex,ey,4.5,3.5,sM,sB);limbSeg(g,ex,ey,gx2,gy,3.5,2.5,sT,sB);g.fillStyle=sM;g.beginPath();g.arc(gx2,gy,3,0,7);g.fill();handR={x:gx2+2,y:gy};}
    else{var ex=cx+34,ey=BY+22,gx2=cx+30,gy=BY+30;limbSeg(g,rx,ry,ex,ey,4,3,sM,sB);limbSeg(g,ex,ey,gx2,gy,3,2,sT,sB);handR={x:gx2,y:gy};}
  })();
  if(work&&handR){var h=handR;
    if(ROOM==="builder"){plate(g,[[h.x-2,h.y+2],[h.x+10,h.y-3],[h.x+14,h.y+2],[h.x+2,h.y+9]],"#2a3444","#12181f","#3d4c63");}
    else if(ROOM==="reviewer"){plate(g,[[h.x-3,h.y-9],[h.x+15,h.y-11],[h.x+15,h.y+2],[h.x-3,h.y+4]],"#1a2836","#0c1620","#3a5570");if(!offl){RB.fillStyle="rgba(130,205,255,0.75)";RB.fillRect(h.x+1,h.y-7,10,7);RE.fillStyle="rgba(130,205,255,0.7)";RE.fillRect(h.x+1,h.y-7,10,7);}}
    else{plate(g,[[h.x-2,h.y-11],[h.x+9,h.y-13],[h.x+12,h.y+4],[h.x+1,h.y+6]],"#241a30","#140e1c","#4a3a5e");if(!offl){RB.fillStyle="rgba(201,139,255,0.75)";RB.fillRect(h.x+2,h.y-9,4,5);RE.fillStyle="rgba(201,139,255,0.7)";RE.fillRect(h.x+2,h.y-9,4,5);}}
  }

  RB.setTransform(1,0,0,1,0,0);RE.setTransform(1,0,0,1,0,0);RR.setTransform(1,0,0,1,0,0);
  buildRim();
  var hh=handR||{x:cx+30,y:BY+28};
  return {hand:{x:TX(hh.x),y:TY(hh.y)},coreY:TY(BY),hy:TY(BY-24),offl:offl,work:work};
}

function drawRobot(t){
  var info=buildRobo(t,STATE);lastHand=info.hand;
  var sc=0.74, px=ROBOX-260*sc, py=FLOORY-560*sc;
  if(AGENT==="kimi"&&!info.offl)py-=48;   // kimi hovers higher in the full room (mini already sits ideally)
  // cast shadow
  var floating=(AGENT==="grok"||AGENT==="kimi"), shcx=floating?ROBOX:ROBOX+54, shW=floating?86:182, shH=floating?16:26, shA=floating?0.4:0.72;
  S.save();var sh=S.createRadialGradient(shcx,FLOORY+8,4,shcx,FLOORY+8,shW+8);sh.addColorStop(0,"rgba(0,0,0,"+shA+")");sh.addColorStop(1,"rgba(0,0,0,0)");S.fillStyle=sh;S.beginPath();S.ellipse(shcx,FLOORY+8,shW,shH,0,0,7);S.fill();S.restore();
  if(!info.offl&&AGENT!=="claude"){var vc=AGENT==="codex"?"55,212,166":AGENT==="grok"?"176,124,255":"255,114,182",vr=floating?122:150;S.save();S.globalCompositeOperation="lighter";var tgl=S.createRadialGradient(ROBOX,FLOORY,2,ROBOX,FLOORY,vr);tgl.addColorStop(0,"rgba("+vc+",0.14)");tgl.addColorStop(1,"rgba("+vc+",0)");S.fillStyle=tgl;S.beginPath();S.ellipse(ROBOX,FLOORY+4,vr,18,0,0,7);S.fill();S.restore();}
  // body
  S.imageSmoothingEnabled=true;
  S.drawImage(robo,px,py,RW*sc,RH*sc);
  // rim additive
  S.save();S.globalCompositeOperation="lighter";S.globalAlpha=info.offl?0.5:0.95;S.drawImage(rrim,px,py,RW*sc,RH*sc);S.restore();
  // emissive -> glow buffer (scaled)
  G.save();G.globalCompositeOperation="lighter";G.drawImage(remit,px,py,RW*sc,RH*sc);G.restore();
  // working effect at the hand — role-specific
  var hx=px+info.hand.x*sc, hyy=py+info.hand.y*sc, visor={x:ROBOX,y:py+(info.hy+20)*sc};
  if(info.work){
    if(ROOM==="builder"){ // weld arc + spark shower
      var flick=0.4+0.42*Math.sin(t*40)+ (Math.random()<0.15?0.35:0);
      emit(function(c){c.save();c.globalCompositeOperation="lighter";var ag=c.createRadialGradient(hx,hyy,1,hx,hyy,20);ag.addColorStop(0,rgba(210,232,255,Math.min(0.9,flick)));ag.addColorStop(0.35,rgba(120,190,255,0.42*flick));ag.addColorStop(1,"rgba(90,160,255,0)");c.fillStyle=ag;c.beginPath();c.arc(hx,hyy,20,0,7);c.fill();c.fillStyle=rgba(255,255,255,Math.min(0.9,flick));c.beginPath();c.arc(hx,hyy,2.4,0,7);c.fill();c.restore();});
      if(!reduced&&Math.random()<0.55)for(var s=0;s<3;s++)sparks.push({x:hx,y:hyy,vx:(Math.random()-0.5)*1.5,vy:1.6+Math.random()*2.6,life:0.3+Math.random()*0.35});
    } else if(ROOM==="reviewer"){ // floating diff-scan hologram + sweep + beam
      var pw=66,ph=48,pxp=hx-6,pyp=hyy-ph-8;
      emit(function(c){c.save();c.globalCompositeOperation="lighter";c.strokeStyle="rgba(120,200,255,0.16)";c.lineWidth=2;c.beginPath();c.moveTo(visor.x,visor.y);c.lineTo(pxp+pw*0.42,pyp+ph*0.5);c.stroke();c.restore();});
      emit(function(c){c.save();c.fillStyle="rgba(90,180,255,0.06)";rr(c,pxp,pyp,pw,ph,4);c.fill();c.strokeStyle="rgba(120,205,255,0.7)";c.lineWidth=1;rr(c,pxp,pyp,pw,ph,4);c.stroke();
        for(var l=0;l<7;l++){var k=l%3,col=k===0?"90,210,130":k===1?"230,100,100":"90,150,210";c.fillStyle="rgba("+col+",0.72)";c.fillRect(pxp+7,pyp+8+l*5,10+((l*13)%40),2);}
        var sb=pyp+6+((t*46)%(ph-12));c.fillStyle="rgba(195,238,255,0.5)";c.fillRect(pxp+3,sb,pw-6,3);c.restore();});
      emit(function(c){var g5=c.createRadialGradient(hx,hyy,1,hx,hyy,12);g5.addColorStop(0,"rgba(150,210,255,0.6)");g5.addColorStop(1,"rgba(150,210,255,0)");c.fillStyle=g5;c.beginPath();c.arc(hx,hyy,12,0,7);c.fill();});
    } else { // triage: dispatch/comm hologram + routing blips + pulse ring
      var cw2=52,ch2=46,cxp=hx-4,cyp=hyy-ch2-8,pulse=0.5+0.5*Math.sin(t*5);
      emit(function(c){c.save();c.globalCompositeOperation="lighter";c.strokeStyle="rgba(201,139,255,0.16)";c.lineWidth=2;c.beginPath();c.moveTo(visor.x,visor.y);c.lineTo(cxp+cw2*0.42,cyp+ch2*0.5);c.stroke();c.restore();});
      emit(function(c){c.save();c.fillStyle="rgba(180,120,255,0.06)";rr(c,cxp,cyp,cw2,ch2,4);c.fill();c.strokeStyle="rgba(201,139,255,0.7)";c.lineWidth=1;rr(c,cxp,cyp,cw2,ch2,4);c.stroke();
        var cols=["247,189,78","92,180,255","95,206,155","255,114,182"];for(var ch=0;ch<4;ch++){var chx=cxp+8+ch*10;c.fillStyle="rgba(80,70,110,0.85)";c.fillRect(chx,cyp+9,2,ch2-16);if((ch+Math.floor(t*2))%2===0){c.fillStyle="rgba("+cols[ch]+",0.9)";c.fillRect(chx-1,cyp+9+((t*30+ch*7)%(ch2-20)),4,3);}}c.restore();});
      emit(function(c){c.save();c.globalCompositeOperation="lighter";c.strokeStyle="rgba(201,139,255,"+(0.5*pulse)+")";c.lineWidth=1.5;c.beginPath();c.arc(hx,hyy,4+9*pulse,0,7);c.stroke();c.fillStyle="rgba(224,186,255,0.85)";c.beginPath();c.arc(hx,hyy,2,0,7);c.fill();c.restore();});
    }
  }
  // offline: "!" alarm diamond above head
  if(info.offl){
    var ax=px+260*sc, ay=py+(info.hy-42)*sc + Math.sin(t*3)*3;
    S.save();S.translate(ax,ay);S.rotate(Math.PI/4);
    S.fillStyle="#1a0d0f";S.fillRect(-11,-11,22,22);
    var p=0.5+0.5*Math.sin(t*6);S.fillStyle=rgba(255,60,50,0.5+0.5*p);S.fillRect(-8,-8,16,16);S.restore();
    S.fillStyle="#ffdcd8";S.font="700 15px "+"ui-monospace,monospace";S.textAlign="center";S.fillText("!",ax,ay+5);S.textAlign="left";
    emit(function(c){c.fillStyle=rgba(255,60,50,0.5*p);c.beginPath();c.arc(ax,ay,14,0,7);c.fill();});
  }
}
function stepSparks(dt){for(var i=sparks.length-1;i>=0;i--){var s=sparks[i];s.x+=s.vx;s.y+=s.vy;s.vy+=0.12;s.life-=dt;if(s.life<=0||s.y>FLOORY+6)sparks.splice(i,1);}}
function drawSparks(){S.save();S.globalCompositeOperation="lighter";sparks.forEach(function(s){var a=Math.min(1,s.life*2);S.fillStyle=rgba(255,200,120,a);S.fillRect(s.x,s.y,2,2);G.fillStyle=rgba(255,180,90,a*0.8);G.fillRect(s.x,s.y,2,2);});S.restore();}

/* ===================== SCENE ENV ===================== */
function drawTarget(t,dt){
  var offl=STATE==="offline", work=STATE==="working";
  stepLamp(t,dt,!offl);var lit=lamp.lit*(work?1:0.8);
  S.setTransform(1,0,0,1,0,0);S.globalAlpha=1;S.globalCompositeOperation="source-over";S.filter="none";
  G.setTransform(1,0,0,1,0,0);G.globalAlpha=1;G.globalCompositeOperation="source-over";G.filter="none";
  S.clearRect(0,0,DW,DH);G.clearRect(0,0,DW,DH);
  S.fillStyle="#02040a";S.fillRect(0,0,DW,DH);
  var cg=S.createLinearGradient(0,0,0,DH);cg.addColorStop(0,"rgba(18,34,54,0.30)");cg.addColorStop(.5,"rgba(6,12,22,0)");S.fillStyle=cg;S.fillRect(0,0,DW,DH);

  drawDeepRacks(t);
  drawBackWall(t,lit);
  rightTower(t);
  drawRedBeacon(t,offl?1:0.14);
  // wall attachments FIRST, so the volumetric light reads in front of them
  if(ROOM==="builder"){ floorHazard(); crane(t); fabBay(t,lit,STATE); pegboard(t,lit); }
  else if(ROOM==="reviewer"){ diffWall(t,STATE); checklistBoard(); }
  else { kanban(t,STATE); radar(t,STATE); switchboard(t,STATE); }
  drawLampCone(t,lit,!offl,ROOM);   // light between wall attachments and robot
  stepSparks(dt);
  drawRobot(t);
  if(ROOM==="builder"){ conveyor(t,STATE); workbench(t,lit,STATE); crateBig(206,558);crateBig(182,588); }
  else if(ROOM==="reviewer"){ inspectDesk(t,STATE); verdictTower(t,STATE); fileCabinet(1040); fileCabinet(1078); docStack(690); docStack(720); }
  else { mapConsole(t,STATE); phoneBank(1042); fileCabinet(1086); docStack(700); }
  drawSparks();
  drawFloorFog(t);
  drawSteam(t);
  drawForeground();

  C.setTransform(1,0,0,1,0,0);C.globalAlpha=1;C.globalCompositeOperation="source-over";C.filter="none";C.clearRect(0,0,DW,DH);
  C.drawImage(scene,0,0);
  C.globalCompositeOperation="lighter";
  C.filter="blur(6px)";C.globalAlpha=0.42;C.drawImage(glow,0,0);
  C.filter="blur(16px)";C.globalAlpha=0.64;C.drawImage(glow,0,0);
  C.filter="blur(34px)";C.globalAlpha=0.46;C.drawImage(glow,0,0);
  C.globalCompositeOperation="source-over";C.filter="none";C.globalAlpha=1;
  C.globalCompositeOperation="overlay";C.globalAlpha=0.05;var nx=-Math.random()*40,ny=-Math.random()*40;
  for(var gx=nx;gx<DW;gx+=220)for(var gy=ny;gy<DH;gy+=220)C.drawImage(noise,gx,gy);
  C.globalCompositeOperation="source-over";C.globalAlpha=0.05;C.fillStyle="#000";for(var sl=0;sl<DH;sl+=3)C.fillRect(0,sl,DW,1);C.globalAlpha=1;
  var vg=C.createRadialGradient(DW*0.46,DH*0.46,DH*0.30,DW*0.5,DH*0.52,DH*0.92);vg.addColorStop(0,"rgba(0,0,0,0)");vg.addColorStop(1,"rgba(0,0,0,0.80)");C.fillStyle=vg;C.fillRect(0,0,DW,DH);
}
function drawDeepRacks(t){
  var defs=[[120,.34,.72],[250,.5,.5],[1060,.32,.75],[1160,.55,.42],[985,.42,.6]];
  defs.forEach(function(d,k){var x=d[0],sc=d[1],fog=d[2],w=120*sc,h=420*sc,y=FLOORY-h+40;
    S.fillStyle=rgba(8,14,22,1-fog*0.4);rr(S,x,y,w,h,4);S.fill();
    S.fillStyle=rgba(20,30,44,0.5*(1-fog));rr(S,x,y,w,6,3);S.fill();
    for(var u=0;u<14;u++){var uy=y+18+u*(h-30)/14;S.fillStyle=rgba(10,16,24,1-fog*0.3);S.fillRect(x+6,uy,w-12,(h-30)/14-3);
      if((u+k)%3===0){var on=(Math.sin(t*2.2+u+k)>0.35);var col=[[95,214,155],[95,180,255],[255,80,70],[247,189,78]][(u+k)%4];var a=(on?0.62:0.12)*(1-fog*0.6);
        emit(function(cx){cx.fillStyle=rgba(col[0],col[1],col[2],a);cx.fillRect(x+w-14,uy+2,4,4);});}}
    S.fillStyle=rgba(6,12,22,fog*0.85);rr(S,x-4,y-4,w+8,h+8,6);S.fill();});
  var fz=S.createLinearGradient(0,FLOORY-360,0,FLOORY);fz.addColorStop(0,"rgba(20,36,58,0)");fz.addColorStop(1,"rgba(24,42,66,0.10)");S.fillStyle=fz;S.fillRect(0,FLOORY-360,DW,360);
}
function drawBackWall(t,lit){
  var wx=250,ww=760,wy=150,wh=FLOORY-150;
  var wallg=S.createLinearGradient(0,wy,0,FLOORY);wallg.addColorStop(0,"#0a1019");wallg.addColorStop(1,"#05080e");S.fillStyle=wallg;S.fillRect(wx,wy,ww,wh);
  S.strokeStyle="rgba(30,44,64,0.25)";S.lineWidth=1;for(var px=wx+80;px<wx+ww;px+=120){S.beginPath();S.moveTo(px,wy);S.lineTo(px,FLOORY);S.stroke();}
  S.beginPath();S.moveTo(wx,wy+150);S.lineTo(wx+ww,wy+150);S.stroke();
  S.save();S.globalAlpha=0.09+0.05*lit;S.fillStyle="#d9b23a";S.font="700 34px ui-monospace,monospace";S.fillText("SECTOR-7",672,wy+70);S.font="700 15px ui-monospace,monospace";S.fillText(ROOM==="builder"?"BUILDER QUARTERS":ROOM==="reviewer"?"REVIEW LAB":"DISPATCH",674,wy+92);S.restore();
  S.save();S.globalAlpha=0.14;for(var sx=wx;sx<wx+ww;sx+=18){S.fillStyle=sx%36<18?"#c9a227":"#0a0a0a";S.beginPath();S.moveTo(sx,FLOORY-8);S.lineTo(sx+9,FLOORY-8);S.lineTo(sx+18,FLOORY);S.lineTo(sx+9,FLOORY);S.closePath();S.fill();}S.restore();
  var flg=S.createLinearGradient(0,FLOORY,0,DH);flg.addColorStop(0,"#060a12");flg.addColorStop(1,"#010307");S.fillStyle=flg;S.fillRect(0,FLOORY,DW,DH-FLOORY);
  S.fillStyle="rgba(0,0,0,0.6)";S.fillRect(0,FLOORY,DW,3);
}
function drawRedBeacon(t,intensity){
  var bx=300,by=200,pulse=reduced?0.6:(0.35+0.65*Math.pow(Math.max(0,Math.sin(t*1.6)),3));
  S.fillStyle="#0f1116";rr(S,bx-2,by+12,30,6,2);S.fill();                 // mount base
  S.fillStyle="#1a1e26";rr(S,bx+2,by+1,22,13,3);S.fill();                 // cage housing
  emit(function(cx){var g2=cx.createRadialGradient(bx+13,by+8,1,bx+13,by+8,10);g2.addColorStop(0,rgba(255,140,130,Math.min(1,0.5+intensity)));g2.addColorStop(0.5,rgba(255,50,44,(0.4+0.6*pulse)*Math.min(1,0.4+intensity)));g2.addColorStop(1,"rgba(255,50,44,0)");cx.fillStyle=g2;cx.beginPath();cx.arc(bx+13,by+8,10,0,7);cx.fill();});
  S.strokeStyle="#0a0c10";S.lineWidth=1;for(var cb=0;cb<3;cb++){S.beginPath();S.moveTo(bx+6+cb*6,by+2);S.lineTo(bx+6+cb*6,by+13);S.stroke();}  // cage bars
  S.save();S.globalCompositeOperation="lighter";var rw=S.createRadialGradient(bx+13,by+30,4,bx+13,by+30,360);rw.addColorStop(0,rgba(255,50,44,0.20*pulse*intensity));rw.addColorStop(1,"rgba(255,50,44,0)");S.fillStyle=rw;S.fillRect(bx-320,by,700,520);S.restore();
}
function drawLampCone(t,lit,on,room){
  var BULB,CONE,POOL,MOTE;
  if(room==="builder"){BULB=[255,214,150];CONE=[255,201,135];POOL=[255,194,130];MOTE=[255,224,170];}
  else if(room==="reviewer"){BULB=[206,230,255];CONE=[150,196,245];POOL=[150,196,245];MOTE=[196,222,255];}
  else {BULB=[214,196,255];CONE=[176,150,240];POOL=[176,150,240];MOTE=[210,196,255];}
  S.fillStyle="#0b0f16";S.fillRect(LAMPX-3,0,6,LAMPY);
  S.fillStyle="#141a24";rr(S,LAMPX-26,LAMPY,52,18,5);S.fill();S.fillStyle="#20293a";rr(S,LAMPX-26,LAMPY,52,5,3);S.fill();
  if(!on){S.fillStyle="#0a0d13";rr(S,LAMPX-9,LAMPY+11,18,7,3);S.fill();return;}
  emit(function(cx){cx.fillStyle=rgba(BULB[0],BULB[1],BULB[2],0.9*lit);rr(cx,LAMPX-9,LAMPY+11,18,7,3);cx.fill();cx.fillStyle=rgba(255,250,235,lit);rr(cx,LAMPX-5,LAMPY+12,10,4,2);cx.fill();});
  var topY=LAMPY+18,spread=190;
  S.save();S.globalCompositeOperation="lighter";
  var cone=S.createLinearGradient(0,topY,0,FLOORY+10);cone.addColorStop(0,rgba(CONE[0],CONE[1],CONE[2],0.20*lit));cone.addColorStop(0.6,rgba(CONE[0],CONE[1],CONE[2],0.07*lit));cone.addColorStop(1,rgba(CONE[0],CONE[1],CONE[2],0));
  S.fillStyle=cone;S.beginPath();S.moveTo(LAMPX-14,topY);S.lineTo(LAMPX+14,topY);S.lineTo(LAMPX+spread,FLOORY+10);S.lineTo(LAMPX-spread,FLOORY+10);S.closePath();S.fill();
  if(!reduced)motes.forEach(function(m){var yy=topY+m.y*(FLOORY-topY);var frac=(yy-topY)/(FLOORY-topY);var half=14+frac*spread;var xx=LAMPX+(m.x-0.5)*2*half+Math.sin(t*0.6+m.s)*6;var a=(0.5+0.5*Math.sin(t*1.4+m.s))*0.5*lit*(1-frac*0.3);S.fillStyle=rgba(MOTE[0],MOTE[1],MOTE[2],a);S.fillRect(xx,yy,m.z*1.6,m.z*1.6);});
  S.restore();
  emit(function(cx){cx.save();cx.globalCompositeOperation="lighter";var p=cx.createRadialGradient(LAMPX,FLOORY,4,LAMPX,FLOORY,spread*0.9);p.addColorStop(0,rgba(POOL[0],POOL[1],POOL[2],0.5*lit));p.addColorStop(0.4,rgba(POOL[0],POOL[1],POOL[2],0.16*lit));p.addColorStop(1,rgba(POOL[0],POOL[1],POOL[2],0));cx.fillStyle=p;cx.beginPath();cx.ellipse(LAMPX,FLOORY+6,spread*0.9,42,0,0,7);cx.fill();cx.restore();});
}
function drawHolo(t,st){
  var offl=st==="offline";
  var jit=reduced?0:(Math.sin(t*40)*0.6+(Math.random()<(offl?0.16:0.03)?Math.random()*(offl?7:3):0));
  var x=HOLOX+jit,y=HOLOY,w=HOLOW,h=HOLOH;
  var C0=offl?[255,74,66]:[95,214,255]; var flick=offl?(Math.random()<0.2?0.3:0.85):1;
  S.save();S.globalCompositeOperation="lighter";S.fillStyle=rgba(C0[0],C0[1],C0[2],0.05*flick);S.beginPath();S.moveTo(ROBOX+150,FLOORY-6);S.lineTo(x+10,y+h);S.lineTo(x+w-10,y+h);S.closePath();S.fill();S.restore();
  function panel(c,alpha){c.save();c.globalAlpha=alpha*flick;
    c.fillStyle=rgba(C0[0],C0[1],C0[2],0.05);rr(c,x,y,w,h,8);c.fill();
    c.strokeStyle=rgba(C0[0],C0[1],C0[2],0.8);c.lineWidth=1.4;rr(c,x,y,w,h,8);c.stroke();
    c.strokeStyle=rgba(C0[0],C0[1],C0[2],1);c.lineWidth=2;[[x,y,1,1],[x+w,y,-1,1],[x,y+h,1,-1],[x+w,y+h,-1,-1]].forEach(function(k){c.beginPath();c.moveTo(k[0],k[1]+14*k[3]);c.lineTo(k[0],k[1]);c.lineTo(k[0]+14*k[2],k[1]);c.stroke();});
    c.fillStyle=rgba(C0[0],C0[1],C0[2],0.9);c.font="700 13px ui-monospace,monospace";
    c.fillText(offl?"◇ SIGNAL LOST":"◆ UNIT DIAGNOSTIC",x+14,y+24);
    c.fillStyle=rgba(C0[0],C0[1],C0[2],0.5);c.fillText(UNIT(),x+14,y+42);
    c.font="12px ui-monospace,monospace";
    var dd=dataOf(BOX,ROOM),up=dd.up.h+"h "+(dd.up.m<10?"0":"")+dd.up.m+"m",ql="q"+dd.queue.length+" · "+dd.repo;
    var rows=offl?[["LINK","— — —","#ff6a62"],["CRON","SILENT","#ff6a62"],["LAST","tick missed",""],["SINCE","00:04:12",""]]
      :st==="working"?[["STATE",ROOM==="builder"?"BUILDING":ROOM==="reviewer"?"REVIEWING":"DISPATCHING","#f7bd4e"],["UPTIME",up,""],["QUEUE",ql,""],["LAST",(dd.sessions.length?dd.sessions[0].out:(dd.cur?dd.cur.key:"—")),""]]
      :[["STATE","STANDBY","#5fce9b"],["UPTIME",up,""],["QUEUE",ql,""],["LAST","idle · awaiting",""]];
    rows.forEach(function(rw,i){var ry=y+70+i*24;c.fillStyle=rgba(C0[0],C0[1],C0[2],0.45);c.fillText(rw[0],x+14,ry);c.fillStyle=rw[2]||rgba(C0[0],C0[1],C0[2],0.9);c.fillText(rw[1],x+96,ry);});
    c.strokeStyle=rgba(C0[0],C0[1],C0[2],0.8);c.lineWidth=1.4;c.beginPath();
    for(var wx2=0;wx2<w-28;wx2+=3){var amp=offl?2:(st==="working"?9:4);var spd=offl?18:(st==="working"?6:2.5);var wy2=y+h-24+Math.sin(wx2*0.25+t*spd)*amp*Math.sin(wx2*0.05)+(offl&&Math.random()<0.1?(Math.random()-0.5)*10:0);if(wx2===0)c.moveTo(x+14+wx2,wy2);else c.lineTo(x+14+wx2,wy2);}c.stroke();
    c.globalAlpha=alpha*flick*0.5;c.fillStyle=rgba(C0[0],C0[1],C0[2],0.06);for(var sl=y+4;sl<y+h;sl+=4)c.fillRect(x+2,sl,w-4,1);
    if(!offl){var sb=y+((t*60)%h);c.fillStyle=rgba(C0[0],C0[1],C0[2],0.10);c.fillRect(x+2,sb,w-4,10);}
    c.restore();}
  panel(S,0.9);panel(G,0.7);
}
function drawFloorFog(t){S.save();S.globalCompositeOperation="lighter";floorHaze.forEach(function(f){var x=((f.x+t*f.sp)%1.2-0.1)*DW;var y=FLOORY+(f.y-0.8)*DH*0.4;var gr=S.createRadialGradient(x,y,10,x,y,260);gr.addColorStop(0,rgba(90,120,150,f.a));gr.addColorStop(1,"rgba(90,120,150,0)");S.fillStyle=gr;S.beginPath();S.ellipse(x,y,260,50,0,0,7);S.fill();});S.restore();}
function drawSteam(t){if(reduced)return;S.save();S.globalCompositeOperation="lighter";var vx=1010,vy=FLOORY-30;S.fillStyle="#0c1219";rr(S,vx,vy,40,26,3);S.fill();steam.forEach(function(s){var p=(s.p+t*0.06)%1;var yy=vy-p*180;var xx=vx+20+Math.sin(t*0.8+s.sway)*24*p;var a=(1-p)*0.10;var rad=8+p*46;var gr=S.createRadialGradient(xx,yy,2,xx,yy,rad);gr.addColorStop(0,rgba(120,150,175,a));gr.addColorStop(1,"rgba(120,150,175,0)");S.fillStyle=gr;S.beginPath();S.arc(xx,yy,rad,0,7);S.fill();});S.restore();}
function drawForeground(){S.save();S.filter="blur(3px)";S.fillStyle="#010307";S.beginPath();S.moveTo(0,DH);S.lineTo(0,DH-54);S.quadraticCurveTo(DW*0.5,DH-96,DW,DH-40);S.lineTo(DW,DH);S.closePath();S.fill();S.strokeStyle="rgba(30,44,62,0.4)";S.lineWidth=2;S.beginPath();S.moveTo(0,DH-52);S.quadraticCurveTo(DW*0.5,DH-94,DW,DH-38);S.stroke();S.restore();}

/* ===================== CURRENT (flat) ===================== */
function drawCurrent(t){
  S.setTransform(1,0,0,1,0,0);S.globalAlpha=1;S.globalCompositeOperation="source-over";S.filter="none";
  S.clearRect(0,0,DW,DH);S.fillStyle="#0b111c";S.fillRect(0,0,DW,DH);
  var wx=250,ww=760,wy=150;S.fillStyle="#121b2c";S.fillRect(wx,wy,ww,FLOORY-wy);S.fillStyle="#0e1626";S.fillRect(0,FLOORY,DW,DH-FLOORY);
  S.strokeStyle="#22304a";S.lineWidth=1;for(var px=wx;px<wx+ww;px+=64){S.beginPath();S.moveTo(px,wy);S.lineTo(px,FLOORY);S.stroke();}
  [[300],[900],[1040]].forEach(function(d){var x=d[0];S.fillStyle="#171f30";S.fillRect(x,FLOORY-260,90,260);S.fillStyle="#2a3852";S.fillRect(x,FLOORY-260,90,6);for(var u=0;u<8;u++){S.fillStyle="#0e1626";S.fillRect(x+6,FLOORY-250+u*30,78,22);S.fillStyle=(u%2?"#3aa06a":"#22344e");S.fillRect(x+72,FLOORY-247+u*30,5,5);}});
  var cx=470,fy=FLOORY,base="#f6a04d",bd="#8a5a2a",bl="#ffce9a";function fr(x,y,w,h,c){S.fillStyle=c;S.fillRect(x,y,w,h);}
  fr(cx-16,fy-58,10,58,bd);fr(cx+6,fy-58,10,58,bd);fr(cx-24,fy-118,48,64,base);fr(cx-24,fy-118,48,3,bl);
  fr(cx-36,fy-116,12,20,base);fr(cx+24,fy-116,12,20,base);fr(cx-34,fy-112,10,54,base);fr(cx+24,fy-112,10,54,base);
  fr(cx-20,fy-166,40,44,bl);fr(cx-16,fy-150,32,12,"#0a0f18");fr(cx-12,fy-146,24,4,"#5cb4ff");fr(cx-8,fy-96,16,16,"#0b1119");fr(cx-4,fy-92,8,8,"#5cb4ff");
  S.fillStyle="#c7d4e4";S.font="700 15px ui-monospace,monospace";S.textAlign="center";S.fillText("claude-builder",cx,fy+34);S.textAlign="left";
  C.setTransform(1,0,0,1,0,0);C.globalAlpha=1;C.globalCompositeOperation="source-over";C.filter="none";C.clearRect(0,0,DW,DH);C.drawImage(scene,0,0);
}

/* ===================== COMPOSE + BLIT ===================== */
var cv=document.getElementById("scene"),X=cv.getContext("2d");
var VW=0,VH=0,dpr=1,dstX=0,dstY=0,dstW=0,dstH=0;
function resize(){dpr=Math.min(2,window.devicePixelRatio||1);VW=window.innerWidth;VH=window.innerHeight;cv.width=Math.floor(VW*dpr);cv.height=Math.floor(VH*dpr);X.setTransform(dpr,0,0,dpr,0,0);var s=Math.min(VW/DW,VH/DH);dstW=DW*s;dstH=DH*s;dstX=(VW-dstW)/2;dstY=(VH-dstH)/2;}
window.addEventListener("resize",resize);
function tintTo(dst,src,r,g,b){var c=dst.getContext("2d");c.globalCompositeOperation="source-over";c.globalAlpha=1;c.filter="none";c.clearRect(0,0,DW,DH);c.drawImage(src,0,0);c.globalCompositeOperation="multiply";c.fillStyle="rgb("+r+","+g+","+b+")";c.fillRect(0,0,DW,DH);c.globalCompositeOperation="source-over";}
function blit(){X.imageSmoothingEnabled=true;X.fillStyle="#000";X.fillRect(0,0,VW,VH);
  if(MODE==="target"){var dx=1.1;tintTo(tintR,comp,255,0,0);tintTo(tintG,comp,0,255,0);tintTo(tintB,comp,0,0,255);X.globalCompositeOperation="lighter";X.drawImage(tintG,dstX,dstY,dstW,dstH);X.drawImage(tintR,dstX+dx,dstY,dstW,dstH);X.drawImage(tintB,dstX-dx,dstY,dstW,dstH);X.globalCompositeOperation="source-over";}
  else{X.drawImage(comp,dstX,dstY,dstW,dstH);}}
var lastT=0;
function frame(ms){var t=ms/1000,dt=Math.min(0.05,(ms-lastT)/1000)||0.016;lastT=ms;if(VIEW==="floor"){drawFloor(t);}else{drawTarget(t,dt);blit();}requestAnimationFrame(frame);}

function refreshChrome(){
  document.getElementById("modelabel").textContent=STATE.toUpperCase();
  document.getElementById("fl").textContent=UNIT()+" · "+(STATE==="offline"?"CRON SILENT":STATE)+" · sector-7";
  var sub=document.getElementById("sub");if(sub)sub.textContent=AGENT+" · "+ROLEWORD()+" quarters — detailed god-view cell";
}
var _un=document.getElementById("un");if(_un)_un.addEventListener("click",function(e){var b=e.target.closest("button");if(!b)return;AGENT=b.dataset.a;[].forEach.call(this.querySelectorAll("button"),function(x){x.classList.toggle("on",x===b);});refreshChrome();populateDash();});
var _stg=document.getElementById("stg");if(_stg)_stg.addEventListener("click",function(e){var b=e.target.closest("button");if(!b)return;STATE=b.dataset.s;[].forEach.call(this.querySelectorAll("button"),function(x){x.className=(x===b?"on "+(STATE==="working"?"w":STATE==="offline"?"o":""):"");});refreshChrome();populateDash();});
var _rm=document.getElementById("rm");if(_rm)_rm.addEventListener("click",function(e){var b=e.target.closest("button");if(!b)return;ROOM=b.dataset.r;[].forEach.call(this.querySelectorAll("button"),function(x){x.classList.toggle("on",x===b);});refreshChrome();populateDash();});
/* ---- command-center wiring ---- */
buildTiles();buildOps();
for(var _sd=0;_sd<6;_sd++)tickerEvent();
/* Opened as a file there is no collector to act through, so the operator
   controls stay shown-but-disabled. Serving the page with `crew floor` is what
   turns them on — goLive() clears every .woff below. */
var CTL_TIP="Open this page with `crew floor` — a served page drives the boxes from the host.";
if(!LIVE){["g-start","g-stop","g-wake","a-pause","a-restart","c-send"].forEach(function(id){var e=document.getElementById(id);if(e){e.classList.add("woff");e.title=CTL_TIP;}});var cin=document.getElementById("c-in");if(cin){cin.disabled=true;cin.classList.add("woff");cin.placeholder="Messaging needs a served page — run: crew floor";}}
/* Fleet-wide actions. "Start/Stop all" are box lifecycle, not a mood: they
   power the roster's boxes up and down. "Wake silent" resumes a paused crontab
   and starts a stopped box — it does NOT start a model session, because a box
   whose cron is dead has no evidence anyone asked for one. */
document.getElementById("g-start").addEventListener("click",function(){if(!LIVE)return;if(confirm("Start every roster box?"))cmd("start-all");});
document.getElementById("g-stop").addEventListener("click",function(){if(!LIVE)return;if(confirm("Stop every roster box? Running sessions are lost."))cmd("stop-all");});
document.getElementById("g-wake").addEventListener("click",function(){if(!LIVE)return;cmd("wake-silent");});
setInterval(tickOps,1000);setInterval(updateCurrent,1000);
/* The access panel is re-rendered on every poll, so its buttons are handled by
   delegation on the rail rather than bound per render. */
var _railL=document.querySelector(".rail-l");
if(_railL)_railL.addEventListener("click",function(e){
  if(!LIVE)return;
  var box=BOX,d=dataOf(BOX,ROOM);
  var pw=e.target.closest(".pw");
  if(pw){
    var on=pw.dataset.pw==="on";
    if(!on&&!confirm("Power off "+box+"? Any running session is lost."))return;
    cmd(on?"power-on":"power-off",{box:box});return;
  }
  var b=e.target.closest(".lbtn");if(!b)return;
  if(b.id==="ac-restart"){if(confirm("Restart "+box+"? It is stopped and started again."))cmd("restart",{box:box});}
  else if(b.id==="ac-repo"){if(d.repo)window.open(repoURL(d.repo),"_blank","noopener");}
  else if(b.id==="ac-term"){
    /* A browser cannot open a shell into a box. Hand over the command the
       operator would type instead of pretending otherwise. */
    var c="box shell "+box;
    if(navigator.clipboard&&navigator.clipboard.writeText)navigator.clipboard.writeText(c).then(function(){setStatus("copied: "+c,false);},function(){setStatus(c,false);});
    else setStatus(c,false);
  }
  else if(b.id==="ac-logs")openLogs(box,"");
});
/* Raw logs come back as text/plain from the collector, which tails them in the
   box — the page never gets shell access to a path.

   Shown in an in-page overlay, NOT window.open: the window would be opened in
   the fetch's .then(), which browsers no longer treat as user-initiated, so a
   default popup blocker eats it and the button appears to do nothing. */
function openLogs(box,file){
  setStatus("fetching logs…",false);
  fetch(apiURL("/api/logs?box="+encodeURIComponent(box)+(file?"&file="+encodeURIComponent(file):"")))
    .then(function(r){return r.text();})
    .then(function(txt){
      var ov=document.getElementById("logov");
      if(!ov){
        ov=document.createElement("div");ov.id="logov";
        ov.innerHTML='<div class="logbox"><div class="loghd"><span id="logttl"></span><button id="logx">✕ close</button></div><pre id="logtx"></pre></div>';
        document.body.appendChild(ov);
        ov.addEventListener("click",function(e){if(e.target===ov||e.target.id==="logx")closeLogs();});
      }
      document.getElementById("logttl").textContent=box+" · "+(file||"duty.log");
      document.getElementById("logtx").textContent=txt||"(empty)";
      ov.style.display="flex";
      var tx=document.getElementById("logtx");tx.scrollTop=tx.scrollHeight;
      setStatus("logs: "+box,false);
    })
    .catch(function(e){setStatus("logs failed: "+e.message,true);});
}
function closeLogs(){var ov=document.getElementById("logov");if(ov)ov.style.display="none";}
document.getElementById("filters").addEventListener("click",function(e){var b=e.target.closest(".fchip");if(!b)return;var f=b.dataset.f;floorFilter[f]=b.dataset.v;[].forEach.call(this.querySelectorAll('.fchip[data-f="'+f+'"]'),function(x){x.classList.toggle("on",x===b);});});
/* Pause/Resume is the box's crontab, not its power: the engine stops being
   woken, the box stays up and reachable. That is the reversible control an
   operator actually wants mid-incident. */
document.getElementById("a-pause").addEventListener("click",function(){
  if(!LIVE)return;var d=dataOf(BOX,ROOM);cmd(d.paused?"resume":"pause",{box:BOX});
});
document.getElementById("a-restart").addEventListener("click",function(){
  if(!LIVE)return;var box=BOX;
  if(confirm("Restart "+box+"? It is stopped and started again."))cmd("restart",{box:box});
});
document.getElementById("a-logs").addEventListener("click",function(){
  if(LIVE)return openLogs(BOX,"");
  var f=document.getElementById("dfeed");if(f)f.scrollTop=f.scrollHeight;
});
/* A message starts a real one-shot session of the box's own vendor CLI, fired
   from the host. It is refused for an unreachable box — there is nothing to
   run it. */
function sendMsg(){
  if(!LIVE)return;
  var inp=document.getElementById("c-in"),v=inp.value.trim();if(!v)return;
  var box=BOX;
  if(STATE==="offline"){setStatus("cannot message "+box+" — it is not running",true);return;}
  inp.value="";
  var f=document.getElementById("dfeed");
  if(f){var el=document.createElement("div");el.className="fev";el.innerHTML='<span class="ago">now</span><span style="color:#5fd6ff">📨 prompt</span><span style="color:#c7d4e4">'+esc(v.slice(0,42))+'</span>';f.insertBefore(el,f.firstChild);}
  cmd("message",{box:box,prompt:v});
}
document.getElementById("c-send").addEventListener("click",sendMsg);
document.getElementById("c-in").addEventListener("keydown",function(e){if(e.key==="Enter")sendMsg();e.stopPropagation();});
setInterval(function(){var c=document.getElementById("clock");if(c)c.textContent=clockStr();},1000);
setInterval(tickerEvent,1500);
refreshChrome();
/* ---- god-view floor interactions ---- */
var backBtn=document.getElementById("back");if(backBtn)backBtn.addEventListener("click",toFloor);
cv.addEventListener("mousedown",function(e){if(VIEW!=="floor")return;floorDrag=true;floorMoved=false;floorDragX=e.clientX;floorDragCam=floorCam;});
window.addEventListener("mouseup",function(){floorDrag=false;});
cv.addEventListener("mousemove",function(e){var r=cv.getBoundingClientRect();floorMouse.x=e.clientX-r.left;floorMouse.y=e.clientY-r.top;
  if(floorDrag){floorCam=floorDragCam-(e.clientX-floorDragX);floorCamTarget=floorCam;if(Math.abs(e.clientX-floorDragX)>4)floorMoved=true;}
  if(VIEW==="floor"){var over=false;for(var k=0;k<floorHits.length;k++){var c=floorHits[k];if(floorMouse.x>=c.x&&floorMouse.x<=c.x+CELLW&&floorMouse.y>=c.y&&floorMouse.y<=c.y+CELLH){over=true;break;}}cv.style.cursor=floorDrag?"grabbing":(over?"pointer":"grab");}else cv.style.cursor="default";});
cv.addEventListener("click",function(e){if(VIEW!=="floor"||floorMoved)return;var r=cv.getBoundingClientRect(),mx=e.clientX-r.left,my=e.clientY-r.top;for(var k=0;k<floorHits.length;k++){var c=floorHits[k];if(mx>=c.x&&mx<=c.x+CELLW&&my>=c.y&&my<=c.y+CELLH){focusUnit(c.i);return;}}});
cv.addEventListener("wheel",function(e){if(VIEW!=="floor")return;e.preventDefault();floorCamTarget+=(e.deltaX||e.deltaY);},{passive:false});
document.addEventListener("keydown",function(e){
  if(e.key!=="Escape")return;
  /* Esc closes the log overlay first — otherwise it dismisses the room behind
     it and leaves the logs floating over the wrong view. */
  var ov=document.getElementById("logov");
  if(ov&&ov.style.display==="flex")return closeLogs();
  if(VIEW==="room")toFloor();
});
document.body.className="floor";
resize();requestAnimationFrame(frame);
/* Ask for a snapshot immediately, then keep asking. A failure here is the
   normal case for `open index.html` and leaves the page in DEMO mode. */
pollFleet();setInterval(pollFleet,POLL_MS);
})();
