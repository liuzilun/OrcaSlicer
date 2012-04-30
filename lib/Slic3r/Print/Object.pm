package Slic3r::Print::Object;
use Moo;

use Slic3r::Geometry qw(scale);
use Slic3r::Geometry::Clipper qw(diff_ex intersection_ex union_ex);

has 'input_file'        => (is => 'rw', required => 0);
has 'mesh'              => (is => 'rw', required => 0);
has 'x_length'          => (is => 'rw', required => 1);
has 'y_length'          => (is => 'rw', required => 1);

has 'layers' => (
    traits  => ['Array'],
    is      => 'rw',
    #isa     => 'ArrayRef[Slic3r::Layer]',
    default => sub { [] },
);

sub layer_count {
    my $self = shift;
    return scalar @{ $self->layers };
}

sub layer {
    my $self = shift;
    my ($layer_id) = @_;
    
    # extend our print by creating all necessary layers
    
    if ($self->layer_count < $layer_id + 1) {
        for (my $i = $self->layer_count; $i <= $layer_id; $i++) {
            push @{ $self->layers }, Slic3r::Layer->new(id => $i);
        }
    }
    
    return $self->layers->[$layer_id];
}

sub slice {
    my $self = shift;
    
    # process facets
    {
        my $apply_lines = sub {
            my $lines = shift;
            foreach my $layer_id (keys %$lines) {
                my $layer = $self->layer($layer_id);
                $layer->add_line($_) for @{ $lines->{$layer_id} };
            }
        };
        Slic3r::parallelize(
            disable => ($#{$self->mesh->facets} < 500),  # don't parallelize when too few facets
            items => [ 0..$#{$self->mesh->facets} ],
            thread_cb => sub {
                my $q = shift;
                my $result_lines = {};
                while (defined (my $facet_id = $q->dequeue)) {
                    my $lines = $self->mesh->slice_facet($self, $facet_id);
                    foreach my $layer_id (keys %$lines) {
                        $result_lines->{$layer_id} ||= [];
                        push @{ $result_lines->{$layer_id} }, @{ $lines->{$layer_id} };
                    }
                }
                return $result_lines;
            },
            collect_cb => sub {
                $apply_lines->($_[0]);
            },
            no_threads_cb => sub {
                for (0..$#{$self->mesh->facets}) {
                    my $lines = $self->mesh->slice_facet($self, $_);
                    $apply_lines->($lines);
                }
            },
        );
    }
    die "Invalid input file\n" if !@{$self->layers};
    
    # remove last layer if empty
    # (we might have created it because of the $max_layer = ... + 1 code below)
    pop @{$self->layers} if !@{$self->layers->[-1]->surfaces} && !@{$self->layers->[-1]->lines};
    
    foreach my $layer (@{ $self->layers }) {
        Slic3r::debugf "Making surfaces for layer %d (slice z = %f):\n",
            $layer->id, unscale $layer->slice_z if $Slic3r::debug;
        
        # layer currently has many lines representing intersections of
        # model facets with the layer plane. there may also be lines
        # that we need to ignore (for example, when two non-horizontal
        # facets share a common edge on our plane, we get a single line;
        # however that line has no meaning for our layer as it's enclosed
        # inside a closed polyline)
        
        # build surfaces from sparse lines
        $layer->make_surfaces($self->mesh->make_loops($layer));
        
        # free memory
        $layer->lines(undef);
    }
    
    # detect slicing errors
    my $warning_thrown = 0;
    for my $i (0 .. $#{$self->layers}) {
        my $layer = $self->layers->[$i];
        next unless $layer->slicing_errors;
        if (!$warning_thrown) {
            warn "The model has overlapping or self-intersecting facets. I tried to repair it, "
                . "however you might want to check the results or repair the input file and retry.\n";
            $warning_thrown = 1;
        }
        
        # try to repair the layer surfaces by merging all contours and all holes from
        # neighbor layers
        Slic3r::debugf "Attempting to repair layer %d\n", $i;
        
        my (@upper_surfaces, @lower_surfaces);
        for (my $j = $i+1; $j <= $#{$self->layers}; $j++) {
            if (!$self->layers->[$j]->slicing_errors) {
                @upper_surfaces = @{$self->layers->[$j]->slices};
                last;
            }
        }
        for (my $j = $i-1; $j >= 0; $j--) {
            if (!$self->layers->[$j]->slicing_errors) {
                @lower_surfaces = @{$self->layers->[$j]->slices};
                last;
            }
        }
        
        my $union = union_ex([
            map $_->expolygon->contour, @upper_surfaces, @lower_surfaces,
        ]);
        my $diff = diff_ex(
            [ map @$_, @$union ],
            [ map $_->expolygon->holes, @upper_surfaces, @lower_surfaces, ],
        );
        
        @{$layer->slices} = map Slic3r::Surface->new
            (expolygon => $_, surface_type => 'internal'),
            @$diff;
    }
    
    # remove empty layers from bottom
    while (@{$self->layers} && !@{$self->layers->[0]->slices} && !@{$self->layers->[0]->thin_walls}) {
        shift @{$self->layers};
        for (my $i = 0; $i <= $#{$self->layers}; $i++) {
            $self->layers->[$i]->id($i);
        }
    }
    
    warn "No layers were detected. You might want to repair your STL file and retry.\n"
        if !@{$self->layers};
}

sub detect_surfaces_type {
    my $self = shift;
    Slic3r::debugf "Detecting solid surfaces...\n";
    
    # prepare a reusable subroutine to make surface differences
    my $surface_difference = sub {
        my ($subject_surfaces, $clip_surfaces, $result_type) = @_;
        my $expolygons = diff_ex(
            [ map { ref $_ eq 'ARRAY' ? $_ : ref $_ eq 'Slic3r::ExPolygon' ? @$_ : $_->p } @$subject_surfaces ],
            [ map { ref $_ eq 'ARRAY' ? $_ : ref $_ eq 'Slic3r::ExPolygon' ? @$_ : $_->p } @$clip_surfaces ],
            1,
        );
        return grep $_->contour->is_printable,
            map Slic3r::Surface->new(expolygon => $_, surface_type => $result_type), 
            @$expolygons;
    };
    
    for (my $i = 0; $i < $self->layer_count; $i++) {
        my $layer = $self->layers->[$i];
        my $upper_layer = $self->layers->[$i+1];
        my $lower_layer = $i > 0 ? $self->layers->[$i-1] : undef;
        
        my (@bottom, @top, @internal) = ();
        
        # find top surfaces (difference between current surfaces
        # of current layer and upper one)
        if ($upper_layer) {
            @top = $surface_difference->($layer->slices, $upper_layer->slices, 'top');
        } else {
            # if no upper layer, all surfaces of this one are solid
            @top = @{$layer->slices};
            $_->surface_type('top') for @top;
        }
        
        # find bottom surfaces (difference between current surfaces
        # of current layer and lower one)
        if ($lower_layer) {
            @bottom = $surface_difference->($layer->slices, $lower_layer->slices, 'bottom');
        } else {
            # if no lower layer, all surfaces of this one are solid
            @bottom = @{$layer->slices};
            $_->surface_type('bottom') for @bottom;
        }
        
        # now, if the object contained a thin membrane, we could have overlapping bottom
        # and top surfaces; let's do an intersection to discover them and consider them
        # as bottom surfaces (to allow for bridge detection)
        if (@top && @bottom) {
            my $overlapping = intersection_ex([ map $_->p, @top ], [ map $_->p, @bottom ]);
            Slic3r::debugf "  layer %d contains %d membrane(s)\n", $layer->id, scalar(@$overlapping);
            @top = $surface_difference->([@top], $overlapping, 'top');
        }
        
        # find internal surfaces (difference between top/bottom surfaces and others)
        @internal = $surface_difference->($layer->slices, [@top, @bottom], 'internal');
        
        # save surfaces to layer
        @{$layer->slices} = (@bottom, @top, @internal);
        
        Slic3r::debugf "  layer %d has %d bottom, %d top and %d internal surfaces\n",
            $layer->id, scalar(@bottom), scalar(@top), scalar(@internal);
    }
    
    # clip surfaces to the fill boundaries
    foreach my $layer (@{$self->layers}) {
        @{$layer->surfaces} = ();
        foreach my $surface (@{$layer->slices}) {
            my $intersection = intersection_ex(
                [ $surface->p ],
                [ map @$_, @{$layer->fill_boundaries} ],
            );
            push @{$layer->surfaces}, map Slic3r::Surface->new
                (expolygon => $_, surface_type => $surface->surface_type),
                @$intersection;
        }
        
        # free memory
        @{$layer->fill_boundaries} = ();
    }
}

sub discover_horizontal_shells {
    my $self = shift;
    
    Slic3r::debugf "==> DISCOVERING HORIZONTAL SHELLS\n";
    
    for (my $i = 0; $i < $self->layer_count; $i++) {
        my $layer = $self->layers->[$i];
        foreach my $type (qw(top bottom)) {
            # find surfaces of current type for current layer
            # and offset them to take perimeters into account
            my @surfaces = map $_->offset($Slic3r::perimeters * scale $Slic3r::flow_width),
                grep $_->surface_type eq $type, @{$layer->fill_surfaces} or next;
            my $surfaces_p = [ map $_->p, @surfaces ];
            Slic3r::debugf "Layer %d has %d surfaces of type '%s'\n",
                $i, scalar(@surfaces), $type;
            
            for (my $n = $type eq 'top' ? $i-1 : $i+1; 
                    abs($n - $i) <= $Slic3r::solid_layers-1; 
                    $type eq 'top' ? $n-- : $n++) {
                
                next if $n < 0 || $n >= $self->layer_count;
                Slic3r::debugf "  looking for neighbors on layer %d...\n", $n;
                
                my @neighbor_surfaces = @{$self->layers->[$n]->surfaces};
                my @neighbor_fill_surfaces = @{$self->layers->[$n]->fill_surfaces};
                
                # find intersection between neighbor and current layer's surfaces
                # intersections have contours and holes
                my $new_internal_solid = intersection_ex(
                    $surfaces_p,
                    [ map $_->p, grep $_->surface_type =~ /internal/, @neighbor_surfaces ],
                    undef, 1,
                );
                next if !@$new_internal_solid;
                
                # internal-solid are the union of the existing internal-solid surfaces
                # and new ones
                my $internal_solid = union_ex([
                    ( map $_->p, grep $_->surface_type eq 'internal-solid', @neighbor_fill_surfaces ),
                    ( map @$_, @$new_internal_solid ),
                ]);
                
                # subtract intersections from layer surfaces to get resulting inner surfaces
                my $internal = diff_ex(
                    [ map $_->p, grep $_->surface_type eq 'internal', @neighbor_fill_surfaces ],
                    [ map @$_, @$internal_solid ],
                );
                Slic3r::debugf "    %d internal-solid and %d internal surfaces found\n",
                    scalar(@$internal_solid), scalar(@$internal);
                
                # Note: due to floating point math we're going to get some very small
                # polygons as $internal; they will be removed by removed_small_features()
                
                # assign resulting inner surfaces to layer
                my $neighbor_fill_surfaces = $self->layers->[$n]->fill_surfaces;
                @$neighbor_fill_surfaces = ();
                push @$neighbor_fill_surfaces, Slic3r::Surface->new
                    (expolygon => $_, surface_type => 'internal')
                    for @$internal;
                
                # assign new internal-solid surfaces to layer
                push @$neighbor_fill_surfaces, Slic3r::Surface->new
                    (expolygon => $_, surface_type => 'internal-solid')
                    for @$internal_solid;
                
                # assign top and bottom surfaces to layer
                foreach my $s (Slic3r::Surface->group(grep $_->surface_type =~ /top|bottom/, @neighbor_fill_surfaces)) {
                    my $solid_surfaces = diff_ex(
                        [ map $_->p, @$s ],
                        [ map @$_, @$internal_solid, @$internal ],
                    );
                    push @$neighbor_fill_surfaces, Slic3r::Surface->new
                        (expolygon => $_, surface_type => $s->[0]->surface_type, bridge_angle => $s->[0]->bridge_angle)
                        for @$solid_surfaces;
                }
            }
        }
    }
}

# combine fill surfaces across layers
sub infill_every_layers {
    my $self = shift;
    return unless $Slic3r::infill_every_layers > 1 && $Slic3r::fill_density > 0;
    
    # start from bottom, skip first layer
    for (my $i = 1; $i < $self->layer_count; $i++) {
        my $layer = $self->layer($i);
        
        # skip layer if no internal fill surfaces
        next if !grep $_->surface_type eq 'internal', @{$layer->fill_surfaces};
        
        # for each possible depth, look for intersections with the lower layer
        # we do this from the greater depth to the smaller
        for (my $d = $Slic3r::infill_every_layers - 1; $d >= 1; $d--) {
            next if ($i - $d) < 0;
            my $lower_layer = $self->layer($i - 1);
            
            # select surfaces of the lower layer having the depth we're looking for
            my @lower_surfaces = grep $_->depth_layers == $d && $_->surface_type eq 'internal',
                @{$lower_layer->fill_surfaces};
            next if !@lower_surfaces;
            
            # calculate intersection between our surfaces and theirs
            my $intersection = intersection_ex(
                [ map $_->p, grep $_->depth_layers <= $d, @lower_surfaces ],
                [ map $_->p, grep $_->surface_type eq 'internal', @{$layer->fill_surfaces} ],
            );
            next if !@$intersection;
            
            # new fill surfaces of the current layer are:
            # - any non-internal surface
            # - intersections found (with a $d + 1 depth)
            # - any internal surface not belonging to the intersection (with its original depth)
            {
                my @new_surfaces = ();
                push @new_surfaces, grep $_->surface_type ne 'internal', @{$layer->fill_surfaces};
                push @new_surfaces, map Slic3r::Surface->new
                    (expolygon => $_, surface_type => 'internal', depth_layers => $d + 1), @$intersection;
                
                foreach my $depth (reverse $d..$Slic3r::infill_every_layers) {
                    push @new_surfaces, map Slic3r::Surface->new
                        (expolygon => $_, surface_type => 'internal', depth_layers => $depth),
                        
                        # difference between our internal layers with depth == $depth
                        # and the intersection found
                        @{diff_ex(
                            [
                                map $_->p, grep $_->surface_type eq 'internal' && $_->depth_layers == $depth, 
                                    @{$layer->fill_surfaces},
                            ],
                            [ map @$_, @$intersection ],
                            1,
                        )};
                }
                @{$layer->fill_surfaces} = @new_surfaces;
            }
            
            # now we remove the intersections from lower layer
            {
                my @new_surfaces = ();
                push @new_surfaces, grep $_->surface_type ne 'internal', @{$lower_layer->fill_surfaces};
                foreach my $depth (1..$Slic3r::infill_every_layers) {
                    push @new_surfaces, map Slic3r::Surface->new
                        (expolygon => $_, surface_type => 'internal', depth_layers => $depth),
                        
                        # difference between internal layers with depth == $depth
                        # and the intersection found
                        @{diff_ex(
                            [
                                map $_->p, grep $_->surface_type eq 'internal' && $_->depth_layers == $depth, 
                                    @{$lower_layer->fill_surfaces},
                            ],
                            [ map @$_, @$intersection ],
                            1,
                        )};
                }
                @{$lower_layer->fill_surfaces} = @new_surfaces;
            }
        }
    }
}

sub generate_support_material {
    my $self = shift;
    my %params = @_;
    
    # determine unsupported surfaces
    my %layers = ();
    my @unsupported_expolygons = ();
    {
        my (@a, @b) = ();
        for my $i (reverse 0 .. $#{$self->layers}) {
            my $layer = $self->layers->[$i];
            my @c = ();
            if (@b) {
                @c = @{diff_ex(
                    [ map @$_, @b ],
                    [ map @$_, map $_->expolygon->offset_ex(scale $Slic3r::flow_width), @{$layer->slices} ],
                )};
                $layers{$i} = [@c];
            }
            @b = @{union_ex([ map @$_, @c, @a ])};
            
            # get unsupported surfaces for current layer as all bottom slices
            # minus the bridges offsetted to cover their perimeters.
            # actually, we are marking as bridges more than we should be, so 
            # better build support material for bridges too rather than ignoring
            # those parts. a visibility check algorithm is needed.
            # @a = @{diff_ex(
            #     [ map $_->p, grep $_->surface_type eq 'bottom', @{$layer->slices} ],
            #     [ map @$_, map $_->expolygon->offset_ex(scale $Slic3r::flow_spacing * $Slic3r::perimeters),
            #         grep $_->surface_type eq 'bottom' && defined $_->bridge_angle,
            #         @{$layer->fill_surfaces} ],
            # )};
            @a = map $_->expolygon->clone, grep $_->surface_type eq 'bottom', @{$layer->slices};
            
            $_->simplify(scale $Slic3r::flow_spacing * 3) for @a;
            push @unsupported_expolygons, @a;
        }
    }
    return if !@unsupported_expolygons;
    
    # generate paths for the pattern that we're going to use
    my $support_patterns = [];
    {
        my @support_material_areas = map $_->offset_ex(scale 5),
            @{union_ex([ map @$_, @unsupported_expolygons ])};
        
        my $fill = Slic3r::Fill->new(print => $params{print});
        foreach my $layer (map $self->layers->[$_], 0,1,2) {  # ugly hack
            $fill->filler('honeycomb')->layer($layer);
            my @patterns = ();
            foreach my $expolygon (@support_material_areas) {
                my @paths = $fill->filler('honeycomb')->fill_surface(
                    Slic3r::Surface->new(
                        expolygon       => $expolygon,
                        #bridge_angle    => $Slic3r::fill_angle + 45 + $angle,
                    ),
                    density         => 0.20,
                    flow_spacing    => $Slic3r::flow_spacing,
                );
                my $params = shift @paths;
                
                push @patterns,
                    map Slic3r::ExtrusionPath->new(
                        polyline        => Slic3r::Polyline->new(@$_),
                        role            => 'support-material',
                        depth_layers    => 1,
                        flow_spacing    => $params->{flow_spacing},
                    ), @paths;
            }
            push @$support_patterns, [@patterns];
        }
    }
    
    if (0) {
        require "Slic3r/SVG.pm";
        Slic3r::SVG::output(undef, "support.svg",
            polylines        => [ map $_->polyline, map @$_, @$support_patterns ],
        );
    }
    
    # apply the pattern to layers
    {
        my $clip_pattern = sub {
            my ($layer_id, $expolygons) = @_;
            my @paths = ();
            foreach my $expolygon (@$expolygons) {
                push @paths, map $_->clip_with_expolygon($expolygon),
                    map $_->clip_with_polygon($expolygon->bounding_box_polygon),
                    @{$support_patterns->[ $layer_id % @$support_patterns ]};
            };
            return @paths;
        };
        my %layer_paths = ();
        Slic3r::parallelize(
            items => [ keys %layers ],
            thread_cb => sub {
                my $q = shift;
                my $paths = {};
                while (defined (my $layer_id = $q->dequeue)) {
                    $paths->{$layer_id} = [ $clip_pattern->($layer_id, $layers{$layer_id}) ];
                }
                return $paths;
            },
            collect_cb => sub {
                my $paths = shift;
                $layer_paths{$_} = $paths->{$_} for keys %$paths;
            },
            no_threads_cb => sub {
                $layer_paths{$_} = [ $clip_pattern->($_, $layers{$_}) ] for keys %layers;
            },
        );
        
        foreach my $layer_id (keys %layer_paths) {
            my $layer = $self->layers->[$layer_id];
            $layer->support_fills(Slic3r::ExtrusionPath::Collection->new);
            push @{$layer->support_fills->paths}, @{$layer_paths{$layer_id}};
        }
    }
}

1;
