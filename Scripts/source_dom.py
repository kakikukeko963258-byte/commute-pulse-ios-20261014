from html.parser import HTMLParser
from html import unescape
class Node:
 def __init__(self,tag='root',attrs=None):self.tag=tag;self.attrs=dict(attrs or []);self.children=[]
 def text(self):return ''.join(x if isinstance(x,str) else x.text() for x in self.children)
 def all(self,tag=None,cls=None):
  found=[]
  for x in self.children:
   if not isinstance(x,Node):continue
   if (tag is None or x.tag==tag) and (cls is None or cls in x.attrs.get('class','').split()):found.append(x)
   found.extend(x.all(tag,cls))
  return found
class DOM(HTMLParser):
 def __init__(self,s):
  super().__init__();self.root=Node();self.stack=[self.root];self.feed(s)
 def handle_starttag(self,tag,attrs):
  n=Node(tag,attrs);self.stack[-1].children.append(n)
  if tag not in ['br','img','meta','link','input','hr','source','wbr']:self.stack.append(n)
 def handle_startendtag(self,tag,attrs):self.stack[-1].children.append(Node(tag,attrs))
 def handle_endtag(self,tag):
  for i in range(len(self.stack)-1,0,-1):
   if self.stack[i].tag==tag:self.stack=self.stack[:i];break
 def handle_data(self,d):self.stack[-1].children.append(d)
