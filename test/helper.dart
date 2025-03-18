import 'dart:math';

typedef Edge = ({String node1, String node2, int weight});
void main() {
  final r = Random(1234);
  final nodes = [
    "orchestra",
    "regret",
    "engine",
    "medicine",
    "workshop",
    "basketball",
    "read",
    "fleet",
    "left",
    "charge",
    "fuel",
    "beach",
    "solve",
    "technique",
    "worth",
    "freedom",
    "heavy",
    "reliable",
    "compose",
    "danger",
    "leaflet",
    "intervention",
    "archive",
    "screw",
    "pound",
    "negotiation",
    "cage",
    "chimpanzee",
    "censorship",
    "quality",
    "top",
    "house",
    "contact",
    "courage",
    "hurt",
    "symptom",
    "regulation",
    "remark",
    "so",
    "pressure",
    "habitat",
    "wash",
    "flawed",
    "broken",
    "file",
    "fix",
    "edition",
    "promise",
    "exclusive",
    "humor"
  ];
  List<Edge> edges = [];
  //use flood fill to check if all nodes are connected
  List<Edge> edgesForNode(String node) => edges.where((edge) {
        return edge.node1 == node || edge.node2 == node;
      }).toList();

  bool allReachable() {
    final visitQ = <String>[];
    final visited = <String>{};
    visitQ.add(nodes[0]);
    while (visitQ.isNotEmpty) {
      final node = visitQ.removeLast();
      visited.add(node);
      final edges = edgesForNode(node);
      for (final edge in edges) {
        final nextNode = edge.node1 == node ? edge.node2 : edge.node1;
        if (!visited.contains(nextNode) && !visitQ.contains(nextNode)) {
          visitQ.add(nextNode);
        }
      }
    }

    return visited.length == nodes.length;
  }

  void addRandomEdge() {
    final node1 = nodes[r.nextInt(nodes.length)];
    var node2 = nodes[r.nextInt(nodes.length)];
    while (node1 == node2) {
      node2 = nodes[r.nextInt(nodes.length)];
    }
    final weight = r.nextInt(100);
    edges.add((node1: node1, node2: node2, weight: weight));
  }

  while (!allReachable()) {
    addRandomEdge();
  }

  //random extra edges
  final extra = r.nextInt(30) + 20;
  for (var i = 0; i < extra; i++) {
    addRandomEdge();
  }

  for (final edge in edges) {
    print("g:add_edge('${edge.node1}', '${edge.node2}', ${edge.weight});");
  }
  for (final edge in edges) {
    print("g.addEdge('${edge.node1}', '${edge.node2}', ${edge.weight});");
  }
}
