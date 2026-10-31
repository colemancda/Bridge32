// Exercises the libstdc++ red-black tree helpers Bridge32 implements, the
// way std::map uses them: a header node, insert_and_rebalance after finding
// the insert position, increment/decrement for iteration, and
// rebalance_for_erase. Checks order and the red-black invariants.
#include <stdio.h>
#include <stdlib.h>

typedef struct Node {
    int color;  // red 0, black 1
    struct Node *parent, *left, *right;
    int key;
} Node;

void rb_insert(int insertLeft, Node *x, Node *p, Node *header)
    __asm("__ZSt29_Rb_tree_insert_and_rebalancebPSt18_Rb_tree_node_baseS0_RS_");
Node *rb_erase(Node *z, Node *header) __asm("__ZSt28_Rb_tree_rebalance_for_erasePSt18_Rb_tree_node_baseRS_");
Node *rb_next(Node *x) __asm("__ZSt18_Rb_tree_incrementPSt18_Rb_tree_node_base");
Node *rb_prev(Node *x) __asm("__ZSt18_Rb_tree_decrementPSt18_Rb_tree_node_base");

static Node header;
static int count;

static void insert(int key) {
    Node *p = &header, *x = header.parent;
    while (x) {
        p = x;
        x = key < x->key ? x->left : x->right;
    }
    Node *n = calloc(1, sizeof *n);
    n->key = key;
    rb_insert(p == &header || key < p->key, n, p, &header);
    count++;
}

static Node *find(int key) {
    Node *x = header.parent;
    while (x && x->key != key) x = key < x->key ? x->left : x->right;
    return x;
}

// Returns the black height, or -1 if a red-black property is broken.
static int check(Node *n) {
    if (!n) return 1;
    if (n->color == 0 && ((n->left && n->left->color == 0) || (n->right && n->right->color == 0))) return -1;
    if ((n->left && n->left->parent != n) || (n->right && n->right->parent != n)) return -1;
    int l = check(n->left), r = check(n->right);
    if (l < 0 || r < 0 || l != r) return -1;
    return l + (n->color == 1);
}

static int verify(const char *phase) {
    int seen = 0, ok = 1, last = -1;
    for (Node *n = header.left; n != &header; n = rb_next(n)) {
        if (n->key < last) ok = 0;
        last = n->key;
        seen++;
    }
    int backwards = 0;
    for (Node *n = header.right; n != &header; n = rb_prev(n)) backwards++;
    int height = check(header.parent);
    ok = ok && seen == count && backwards == count && height > 0 && (!header.parent || header.parent->color == 1);
    printf("%s: %d nodes, black height %d, %s\n", phase, seen, height, ok ? "ok" : "BROKEN");
    return ok;
}

int main(void) {
    header.color = 0;
    header.left = header.right = &header;
    srand(1234);
    int ok = 1;

    for (int i = 0; i < 2000; i++) insert(rand() % 100000);
    ok &= verify("insert");

    // Erase every other key in order, then some from the ends.
    int erased = 0;
    for (Node *n = header.left; n != &header;) {
        Node *next = rb_next(n);
        if (erased++ % 2 == 0) {
            free(rb_erase(n, &header));
            count--;
        }
        n = next;
    }
    ok &= verify("erase half");

    while (count > 10) {
        free(rb_erase(header.left, &header));
        count--;
        free(rb_erase(header.right, &header));
        count--;
    }
    ok &= verify("erase ends");

    insert(42);
    ok &= find(42) != NULL && verify("reinsert");
    printf("rbtree %s\n", ok ? "passed" : "FAILED");
    return ok ? 0 : 1;
}
