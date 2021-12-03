#include "data.h"
#include "printer.h"
#include "linearizer.h"

PgfLinearizer::TreeNode::TreeNode(PgfLinearizer *linearizer, ref<PgfConcrLin> lin, PgfText *lit)
{
    this->next     = linearizer->root;
    this->next_arg = NULL;
    this->args     = linearizer->args;

    this->fid       = 0;
    this->literal   = lit;
    this->lin       = lin;
    this->lin_index = 0;

    this->value     = 0;
    this->var_count = 0;
    this->var_values= NULL;

    linearizer->root= this;
}

size_t PgfLinearizer::TreeNode::eval_param(PgfLParam *param)
{
    size_t value = param->i0;
    for (size_t j = 0; j < param->n_terms; j++) {
        size_t factor = param->terms[j].factor;
        size_t var    = param->terms[j].var;

        if (var < var_count && var_values[var] != (size_t) -1) {
            value += factor * var_values[var];
        } else {
            throw pgf_error("Unbound variable in resolving a linearization");
        }
    }
    return value;
}

PgfLinearizer::PgfLinearizer(ref<PgfConcr> concr, PgfMarshaller *m) {
    this->concr = concr;
    this->m = m;
    this->root  = NULL;
    this->first = NULL;
    this->args  = NULL;
    this->capit = CAPIT_NONE;
    this->pre_stack = NULL;
};

PgfLinearizer::~PgfLinearizer()
{
    while (first != NULL) {
        TreeNode *next = first->next;
        delete first;
        first = next;
    }

    while (pre_stack != NULL) {
        PreStack *next = pre_stack->next;

        while (pre_stack->bracket_stack != NULL) {
            BracketStack *next = pre_stack->bracket_stack->next;
            delete pre_stack->bracket_stack;

            pre_stack->bracket_stack = next;
        }

        delete pre_stack;
        pre_stack = next;
    }
}

bool PgfLinearizer::resolve()
{
    TreeNode *node = first;
    while (node != NULL) {
        if (node->literal == NULL) {
            size_t n_args = node->lin->args->len / node->lin->res->len;

            while (node->lin_index < node->lin->res->len) {
                size_t offset = node->lin_index*n_args;

                ref<PgfPResult> pres = *vector_elem(node->lin->res,  node->lin_index);

                int i = 0;
                TreeNode *arg = node->args;
                while (arg != NULL) {
                    ref<PgfPArg> parg = vector_elem(node->lin->args, offset+i);

                    if (arg->value < parg->param->i0)
                        break;

                    size_t value = arg->value - parg->param->i0;
                    for (size_t j = 0; j < parg->param->n_terms; j++) {
                        size_t factor    = parg->param->terms[j].factor;
                        size_t var       = parg->param->terms[j].var;
                        size_t var_value;

                        if (var < node->var_count && node->var_values[var] != (size_t) -1) {
                            // The variable already has a value
                            var_value = node->var_values[var];
                        } else {
                            // The variable is not assigned yet
                            var_value = value / factor;

                            // find the range for the variable
                            size_t range = 0;
                            for (size_t k = 0; k < pres->vars->len; k++) {
                                ref<PgfVariableRange> var_range = vector_elem(pres->vars, k);
                                if (var_range->var == var) {
                                    range = var_range->range;
                                    break;
                                }
                            }
                            if (range == 0)
                                throw pgf_error("Unknown variable in resolving a linearization");

                            if (var_value > range)
                                break;

                            // Assign the variable;
                            if (var >= node->var_count) {
                                node->var_values = (size_t*)
                                    realloc(node->var_values, (var+1)*sizeof(size_t));
                                while (node->var_count < var) {
                                    node->var_values[node->var_count++] = (size_t) -1;
                                }
                                node->var_count++;
                            }
                            node->var_values[var] = var_value;
                        }

                        value -= var_value * factor;
                    }

                    if (value != 0)
                        break;

                    arg = arg->next_arg;
                    i++;
                }

                node->lin_index++;

                if (arg == NULL) {
                    node->value = node->eval_param(&pres->param);
                    break;
                }

                // Unbind all variables
                for (size_t j = 0; j < node->var_count; j++) {
                    node->var_values[j] = (size_t) -1;
                }
            }

            if (node->lin_index > node->lin->res->len)
                return false;
        }

        node = node->next;
    }

    return true;
}

void PgfLinearizer::reverse_and_label()
{
    // Reverse the list of nodes and label them with fid;
    int fid = 0;
    TreeNode *node = root;
    while (node != NULL) {
        TreeNode *tmp = node->next;

        node->fid  = fid++;
        node->next = first;

        first = node;
        node  = tmp;
    }
}

void PgfLinearizer::flush_pre_stack(PgfLinearizationOutputIface *out, PgfText *token)
{
    while (pre_stack != NULL) {
        PreStack *pre = pre_stack;
        pre_stack = pre->next;

        for (size_t i = 0; i < pre->sym_kp->alts.len; i++) {
            PgfAlternative *alt = &pre->sym_kp->alts.data[i];
            for (size_t j = 0; j < alt->prefixes->len; j++) {
                ref<PgfText> prefix = *vector_elem(alt->prefixes,j);
                if (textstarts(token, &(*prefix))) {
                    linearize(out, pre->node, alt->form);
                    goto done;
                }
            }
        }

        linearize(out, pre->node, pre->sym_kp->default_form);

    done:
        if (pre->bracket_stack != NULL)
            pre->bracket_stack->flush(out);

        if (pre->bind)
            out->symbol_bind();

        capit    = pre->capit;

        delete pre;
    }
}

void PgfLinearizer::BracketStack::flush(PgfLinearizationOutputIface *out)
{
    if (next != NULL)
        next->flush(out);

    if (begin)
        out->begin_phrase(&node->lin->absfun->type->name, node->fid, field, &node->lin->name);
    else
        out->end_phrase(&node->lin->absfun->type->name, node->fid, field, &node->lin->name);
}

void PgfLinearizer::linearize(PgfLinearizationOutputIface *out, TreeNode *node, size_t d, PgfLParam *r)
{
    TreeNode *arg = node->args;
    while (d > 0) {
        arg = arg->next_arg;
        if (arg == 0)
            throw pgf_error("Found inconsistency in the PMCFG representation");
        d--;
    }
    size_t lindex = node->eval_param(r);
    PgfText *cat = &arg->lin->absfun->type->name;

    PgfText *field = NULL;
    ref<PgfConcrLincat> lincat = namespace_lookup(concr->lincats, cat);
    if (lincat != 0) {
        field = &(**vector_elem(lincat->fields, lindex));
    }

    if (pre_stack == NULL)
        out->begin_phrase(cat, arg->fid, field, &arg->lin->name);
    else {
        BracketStack *bracket = new BracketStack();
        bracket->next  = pre_stack->bracket_stack;
        bracket->begin = true;
        bracket->node  = arg;
        bracket->field = field;
        pre_stack->bracket_stack = bracket;
    }
    linearize(out, arg, lindex);
    if (pre_stack == NULL)
        out->end_phrase(cat, arg->fid, field, &arg->lin->name);
    else {
        BracketStack *bracket = new BracketStack();
        bracket->next  = pre_stack->bracket_stack;
        bracket->begin = false;
        bracket->node  = arg;
        bracket->field = field;
        pre_stack->bracket_stack = bracket;
    }
}

void PgfLinearizer::linearize(PgfLinearizationOutputIface *out, TreeNode *node, ref<Vector<PgfSymbol>> syms)
{
    ref<Vector<PgfHypo>> hypos = node->lin->absfun->type->hypos;

    for (size_t i = 0; i < syms->len; i++) {
        PgfSymbol sym = *vector_elem(syms, i);

        switch (ref<PgfSymbol>::get_tag(sym)) {
        case PgfSymbolCat::tag: {
            auto sym_cat = ref<PgfSymbolCat>::untagged(sym);
            linearize(out, node, sym_cat->d, &sym_cat->r);
            break;
        }
        case PgfSymbolLit::tag: {
            auto sym_lit = ref<PgfSymbolLit>::untagged(sym);
            linearize(out, node, sym_lit->d, &sym_lit->r);
            break;
        }
        case PgfSymbolVar::tag: {
            auto sym_var = ref<PgfSymbolVar>::untagged(sym);
            break;
        }
        case PgfSymbolKS::tag: {
            auto sym_ks = ref<PgfSymbolKS>::untagged(sym);

            flush_pre_stack(out, &sym_ks->token);

            switch (capit) {
            case CAPIT_NONE:
                out->symbol_token(&sym_ks->token);
                break;
            case CAPIT_FIRST: {
                PgfText *cap = (PgfText *) alloca(sizeof(PgfText)+sym_ks->token.size+6);

                const uint8_t *p   = (const uint8_t *) sym_ks->token.text;
                const uint8_t *end = p + sym_ks->token.size;

                uint8_t *q = (uint8_t *) cap->text;

                uint32_t ucs = pgf_utf8_decode(&p);
                ucs = pgf_utf8_to_upper(ucs);
                pgf_utf8_encode(ucs,&q);

                memcpy(q, p, (end - p)+1);
                q += (end - p);

                cap->size = q - (uint8_t *) cap->text;
                out->symbol_token(cap);

                capit = CAPIT_NONE;
                break;
            }
            case CAPIT_ALL: {
                PgfText *cap = (PgfText *) alloca(sizeof(PgfText)+sym_ks->token.size*6);

                const uint8_t *p   = (const uint8_t *) sym_ks->token.text;
                const uint8_t *end = p + sym_ks->token.size;

                uint8_t *q = (uint8_t *) cap->text;

                while (p != end) {
                    uint32_t ucs = pgf_utf8_decode(&p);
                    ucs = pgf_utf8_to_upper(ucs);
                    pgf_utf8_encode(ucs,&q);
                }

                cap->size = q - (uint8_t *) cap->text;
                *q = 0;

                out->symbol_token(cap);

                capit = CAPIT_NONE;
                break;
            }
            }
            break;
        }
        case PgfSymbolKP::tag: {
            auto sym_kp = ref<PgfSymbolKP>::untagged(sym);
            PreStack *pre = new PreStack();
            pre->next   = pre_stack;
            pre->node   = node;
            pre->sym_kp = sym_kp;
            pre->bind   = false;
            pre->capit  = CAPIT_NONE;
            pre->bracket_stack = NULL;
            pre_stack   = pre;
            break;
        }
        case PgfSymbolBIND::tag:
        case PgfSymbolSOFTBIND::tag:
            if (pre_stack == NULL)
                out->symbol_bind();
            else
                pre_stack->bind = true;
            break;
        case PgfSymbolNE::tag:
            out->symbol_ne();
            break;
        case PgfSymbolSOFTSPACE::tag:
            // Nothing to do
            break;
        case PgfSymbolCAPIT::tag:
            if (pre_stack == NULL)
                capit = CAPIT_FIRST;
            else
                pre_stack->capit = CAPIT_FIRST;
            break;
        case PgfSymbolALLCAPIT::tag:
            if (pre_stack == NULL)
                capit = CAPIT_ALL;
            else
                pre_stack->capit = CAPIT_ALL;
            break;
        }
    }
}

void PgfLinearizer::linearize(PgfLinearizationOutputIface *out, TreeNode *node, size_t lindex)
{
    if (node->literal == NULL) {
        size_t n_seqs = node->lin->seqs->len / node->lin->res->len;
        ref<Vector<PgfSymbol>> syms = *vector_elem(node->lin->seqs, (node->lin_index-1)*n_seqs + lindex);
        linearize(out, node, syms);
    } else {
        out->symbol_token(node->literal);
    }
}

PgfExpr PgfLinearizer::eabs(PgfBindType btype, PgfText *name, PgfExpr body)
{
    return 0;
}

PgfExpr PgfLinearizer::eapp(PgfExpr fun, PgfExpr arg)
{
    TreeNode *args = this->args;
    this->args = NULL;
    TreeNode *node = (TreeNode*) m->match_expr(this, arg);
    node->next_arg = args;
    this->args = node;

    return m->match_expr(this, fun);
}

PgfExpr PgfLinearizer::elit(PgfLiteral lit)
{
    return m->match_lit(this, lit);
}

PgfExpr PgfLinearizer::emeta(PgfMetaId meta)
{
    return 0;
}

PgfExpr PgfLinearizer::efun(PgfText *name)
{
    ref<PgfConcrLin> lin = namespace_lookup(concr->lins, name);
    TreeNode *node = new TreeNode(this, lin, NULL);
    return (PgfExpr) node;
}

PgfExpr PgfLinearizer::evar(int index)
{
    return 0;
}

PgfExpr PgfLinearizer::etyped(PgfExpr expr, PgfType ty)
{
    return m->match_expr(this, expr);
}

PgfExpr PgfLinearizer::eimplarg(PgfExpr expr)
{
    return m->match_expr(this, expr);
}

PgfLiteral PgfLinearizer::lint(size_t size, uintmax_t *v)
{
    PgfPrinter printer(NULL,0,NULL);
    printer.lint(size,v);
    return (PgfExpr) new TreeNode(this, 0, printer.get_text());
}

PgfLiteral PgfLinearizer::lflt(double v)
{
    PgfPrinter printer(NULL,0,NULL);
    printer.lflt(v);
    return (PgfExpr) new TreeNode(this, 0, printer.get_text());
}

PgfLiteral PgfLinearizer::lstr(PgfText *v)
{
    return (PgfExpr) new TreeNode(this, 0, textdup(v));
}

PgfType PgfLinearizer::dtyp(size_t n_hypos, PgfTypeHypo *hypos,
                             PgfText *cat,
                             size_t n_exprs, PgfExpr *exprs)
{
    return 0;
}

void PgfLinearizer::free_ref(object x)
{
}

PgfLinearizationOutput::PgfLinearizationOutput() : printer(NULL,0,NULL)
{
    bind = true;
    nonexist = false;
}

PgfText *PgfLinearizationOutput::get_text()
{
    if (nonexist) {
        free(printer.get_text());
        return NULL;
    }
    return printer.get_text();
}

void PgfLinearizationOutput::symbol_token(PgfText *tok)
{
    if (!bind) {
        printer.puts(" ");
    }
    bind = false;

    printer.puts(tok);
}

void PgfLinearizationOutput::begin_phrase(PgfText *cat, int fid, PgfText *ann, PgfText *fun)
{
}

void PgfLinearizationOutput::end_phrase(PgfText *cat, int fid, PgfText *ann, PgfText *fun)
{
}

void PgfLinearizationOutput::symbol_ne()
{
    nonexist = true;
}

void PgfLinearizationOutput::symbol_bind()
{
    bind = true;
}

void PgfLinearizationOutput::symbol_meta(PgfMetaId id)
{
    printer.nprintf(32, "?%d", id);
}
